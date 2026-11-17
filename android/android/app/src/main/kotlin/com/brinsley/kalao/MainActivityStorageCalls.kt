// Storage Access Framework calls for backups (M4.3–M4.5): save a backup
// where the user chooses, and write to / list / prune a backup folder the
// user granted once. Kalao never asks for broad storage permissions.
package com.brinsley.kalao

import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Activity-result launchers must be registered before the activity starts,
 * so [MainActivity] creates this in `onCreate`; each call waits for its own
 * result. One picker is shown at a time.
 */
internal class DocumentPickers(activity: MainActivity) {
    private var pending: CompletableDeferred<Uri?>? = null

    private val create: ActivityResultLauncher<String> = activity.registerForActivityResult(
        ActivityResultContracts.CreateDocument(BACKUP_MIME),
    ) { uri -> complete(uri) }

    private val tree: ActivityResultLauncher<Uri?> = activity.registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri -> complete(uri) }

    private fun complete(uri: Uri?) {
        pending?.complete(uri)
        pending = null
    }

    private suspend fun await(launch: () -> Unit): Uri? {
        pending?.complete(null)
        val result = CompletableDeferred<Uri?>()
        pending = result
        launch()
        return result.await()
    }

    suspend fun createDocument(name: String): Uri? = await { create.launch(name) }

    suspend fun openTree(): Uri? = await { tree.launch(null) }

    companion object {
        const val BACKUP_MIME = "application/octet-stream"
    }
}

internal suspend fun MainActivity.handleCreateDocument(call: MethodCall, result: MethodChannel.Result) {
    val name = call.argument<String>("name") ?: "kalao.kalaobackup"
    result.success(documentPickers.createDocument(name)?.toString())
}

/** Picks a folder and keeps read/write access to it across restarts. */
internal suspend fun MainActivity.handlePickDocumentTree(result: MethodChannel.Result) {
    val uri = documentPickers.openTree()
    if (uri != null) {
        contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }
    result.success(uri?.toString())
}

internal suspend fun MainActivity.handleCopyFileToDocument(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: throw IllegalArgumentException("path")
    val uri = Uri.parse(call.argument<String>("uri") ?: throw IllegalArgumentException("uri"))
    withContext(Dispatchers.IO) { copyInto(File(path), uri) }
    result.success(null)
}

/** Creates `name` in the granted folder and copies `path` into it. */
internal suspend fun MainActivity.handleWriteFileToTree(call: MethodCall, result: MethodChannel.Result) {
    val tree = Uri.parse(call.argument<String>("treeUri") ?: throw IllegalArgumentException("treeUri"))
    val name = call.argument<String>("name") ?: throw IllegalArgumentException("name")
    val path = call.argument<String>("path") ?: throw IllegalArgumentException("path")
    val document = withContext(Dispatchers.IO) {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val created = DocumentsContract.createDocument(
            contentResolver,
            parent,
            DocumentPickers.BACKUP_MIME,
            name,
        ) ?: throw IllegalStateException("Could not create $name in the backup folder")
        try {
            copyInto(File(path), created)
        } catch (e: Exception) {
            DocumentsContract.deleteDocument(contentResolver, created)
            throw e
        }
        created
    }
    result.success(document.toString())
}

/** `[{uri, name, bytes, modified}]` for the files directly in the folder. */
internal suspend fun MainActivity.handleListDocumentTree(call: MethodCall, result: MethodChannel.Result) {
    val tree = Uri.parse(call.argument<String>("treeUri") ?: throw IllegalArgumentException("treeUri"))
    val files = withContext(Dispatchers.IO) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree),
        )
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val rows = mutableListOf<Map<String, Any?>>()
        contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(4) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                rows += mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)).toString(),
                    "name" to cursor.getString(1),
                    "bytes" to cursor.getLong(2),
                    "modified" to cursor.getLong(3),
                )
            }
        }
        rows
    }
    result.success(files)
}

internal suspend fun MainActivity.handleDeleteDocument(call: MethodCall, result: MethodChannel.Result) {
    val uri = Uri.parse(call.argument<String>("uri") ?: throw IllegalArgumentException("uri"))
    result.success(withContext(Dispatchers.IO) { DocumentsContract.deleteDocument(contentResolver, uri) })
}

private fun MainActivity.copyInto(source: File, target: Uri) {
    source.inputStream().use { input ->
        val output = contentResolver.openOutputStream(target, "wt")
            ?: throw IllegalStateException("Could not open the backup location")
        output.use { input.copyTo(it, 256 * 1024) }
    }
}
