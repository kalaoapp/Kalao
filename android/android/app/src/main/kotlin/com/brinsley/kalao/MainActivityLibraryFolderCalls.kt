// Music folders (FEATURES 6.8): list a folder the user granted with
// Storage Access Framework and hand its files to Rust and Dart as
// `/proc/self/fd/<n>` paths, so songs play in place without a copy. The
// walk follows Mornye's SAF scan (`MainActivitySafScan.kt`): one
// DocumentsContract query per directory, change detection by size and
// modification time in Dart.
package com.brinsley.kalao

import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.FileNotFoundException
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** Descriptors Dart opened, by number, until it closes them. */
internal object OpenDocuments {
    private val open = ConcurrentHashMap<Int, ParcelFileDescriptor>()

    fun add(descriptor: ParcelFileDescriptor): Int {
        val fd = descriptor.fd
        open.put(fd, descriptor)?.close()
        return fd
    }

    fun close(fd: Int) {
        open.remove(fd)?.close()
    }
}

/** Audio and lyrics extensions (`import_service.dart` and `core::pairing`). */
private val folderExtensions = setOf(
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "alac", "mp4", "wma", "ape",
    "aiff", "aif", "lrc", "txt", "ttml",
)

/**
 * `[{uri, name, dir, bytes, modified}]` for every audio and lyrics file under
 * the granted folder (`dir` is the path below it, "" at the top). Folders
 * whose name starts with a dot are skipped. Null when Kalao no longer holds
 * read access (the user revoked it, or the folder is gone).
 */
internal suspend fun MainActivity.handleListLibraryFolder(call: MethodCall, result: MethodChannel.Result) {
    val tree = Uri.parse(call.argument<String>("treeUri") ?: throw IllegalArgumentException("treeUri"))
    val files = withContext(Dispatchers.IO) {
        val granted = contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
        if (!granted) return@withContext null
        try {
            listTree(tree)
        } catch (e: SecurityException) {
            null
        } catch (e: FileNotFoundException) {
            null
        }
    }
    result.success(files)
}

private fun MainActivity.listTree(tree: Uri): List<Map<String, Any?>> {
    val columns = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
    )
    val rows = mutableListOf<Map<String, Any?>>()
    val pending = ArrayDeque(listOf(DocumentsContract.getTreeDocumentId(tree) to ""))
    while (pending.isNotEmpty()) {
        val (id, dir) = pending.removeFirst()
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val cursor = contentResolver.query(children, columns, null, null, null)
            ?: throw FileNotFoundException("Cannot list $dir")
        cursor.use {
            while (it.moveToNext()) {
                val name = it.getString(1) ?: continue
                if (it.getString(4) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (!name.startsWith(".")) {
                        pending.addLast(it.getString(0) to if (dir.isEmpty()) name else "$dir/$name")
                    }
                    continue
                }
                val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                if (extension !in folderExtensions) continue
                rows += mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0)).toString(),
                    "name" to name,
                    "dir" to dir,
                    "bytes" to if (it.isNull(2)) 0L else it.getLong(2),
                    "modified" to if (it.isNull(3)) 0L else it.getLong(3),
                )
            }
        }
    }
    return rows
}

/**
 * Opens a document for reading and returns `{path, handle}`: `path` is
 * `/proc/self/fd/<handle>`, which Rust and Dart open like a file while the
 * descriptor stays open. Dart closes it with `closeDocuments`.
 */
internal suspend fun MainActivity.handleOpenDocument(call: MethodCall, result: MethodChannel.Result) {
    val uri = Uri.parse(call.argument<String>("uri") ?: throw IllegalArgumentException("uri"))
    val fd = withContext(Dispatchers.IO) {
        val descriptor = contentResolver.openFileDescriptor(uri, "r")
            ?: throw FileNotFoundException("Cannot open $uri")
        OpenDocuments.add(descriptor)
    }
    result.success(mapOf("path" to "/proc/self/fd/$fd", "handle" to fd))
}

internal fun handleCloseDocuments(call: MethodCall, result: MethodChannel.Result) {
    for (fd in call.argument<List<Int>>("handles").orEmpty()) OpenDocuments.close(fd)
    result.success(null)
}

/** Gives up the access a removed music folder held. */
internal fun MainActivity.handleReleaseDocumentTree(call: MethodCall, result: MethodChannel.Result) {
    val tree = Uri.parse(call.argument<String>("treeUri") ?: throw IllegalArgumentException("treeUri"))
    try {
        contentResolver.releasePersistableUriPermission(
            tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    } catch (e: SecurityException) {
        // Not held any more.
    }
    result.success(null)
}
