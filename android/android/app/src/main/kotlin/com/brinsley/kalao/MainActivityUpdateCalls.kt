// In-app updates: Dart downloads and verifies the APK; Kotlin only
// reports the device ABIs and hands the file to the system installer, which
// checks that its signature matches the installed app.
package com.brinsley.kalao

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal fun handleGetSupportedAbis(result: MethodChannel.Result) {
    result.success(Build.SUPPORTED_ABIS.toList())
}

/**
 * Opens the installer for the APK at `path` (inside `cache/updates/`).
 * Returns false after sending the user to the "install unknown apps"
 * setting when Kalao is not allowed to install yet.
 */
internal fun MainActivity.handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
    val file = File(call.argument<String>("path") ?: throw IllegalArgumentException("path"))
    val updates = File(cacheDir, "updates").canonicalFile
    require(file.canonicalFile.parentFile == updates && file.isFile) { "Not a downloaded update" }
    if (!packageManager.canRequestPackageInstalls()) {
        startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
        )
        result.success(false)
        return
    }
    val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
    startActivity(
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
    )
    result.success(true)
}
