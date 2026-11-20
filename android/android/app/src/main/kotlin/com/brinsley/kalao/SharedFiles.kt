// Files opened with or shared to Kalao: a `.kalaobackup`, lyrics or
// audio. The activity records the intent's URIs; Dart takes them on start
// and resume, as copies in the cache named like the originals.
package com.brinsley.kalao

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File

internal object SharedFiles {
    private val pending = mutableListOf<Uri>()

    /** Remembers the files of a VIEW, SEND or SEND_MULTIPLE [intent]. */
    @Synchronized
    fun collect(intent: Intent?) {
        intent ?: return
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(intent.stream())
            Intent.ACTION_SEND_MULTIPLE -> intent.streams()
            else -> emptyList()
        }
        pending += uris.filter { it.scheme == "content" || it.scheme == "file" }
        // Handled once: a recreated activity must not import it again.
        if (uris.isNotEmpty()) intent.action = Intent.ACTION_MAIN
    }

    /** `[{path, name}]`: the pending files copied into `cache/shared/`. */
    fun take(context: Context): List<Map<String, String>> {
        val uris = synchronized(this) { pending.toList().also { pending.clear() } }
        if (uris.isEmpty()) return emptyList()
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        return uris.mapNotNull { uri ->
            try {
                val name = displayName(context, uri)
                val target = File(dir, "${System.nanoTime()}-$name")
                val input = context.contentResolver.openInputStream(uri) ?: return@mapNotNull null
                input.use { stream -> target.outputStream().use { stream.copyTo(it, 256 * 1024) } }
                mapOf("path" to target.absolutePath, "name" to name)
            } catch (e: Exception) {
                android.util.Log.w("Kalao", "Could not read shared file: ${e.message}")
                null
            }
        }
    }

    /** The file's own name, reduced to safe characters. */
    private fun displayName(context: Context, uri: Uri): String {
        val raw = context.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            ?: uri.lastPathSegment
            ?: "shared"
        val clean = raw.substringAfterLast('/').replace(Regex("""[^\p{L}\p{N}._ ()\-]"""), "_")
        return clean.ifBlank { "shared" }.take(120)
    }

    @Suppress("DEPRECATION")
    private fun Intent.stream(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun Intent.streams(): List<Uri> =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        } ?: emptyList()
}
