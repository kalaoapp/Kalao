// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
package com.brinsley.kalao

import android.content.Intent
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Hosts the Flutter engine and the single backend channel. A call whose name
 * is in [nativeBackendMethods] is handled by the `when` below (Android APIs);
 * every other name goes to the Rust backend through
 * [dispatchBackendApplication]. `MainActivityRoutingTest` keeps the set and
 * the `when` labels in step.
 *
 * The activity uses audio_service's cached engine (as Mornye), so the media
 * session, notification and lock-screen controls share it with the UI.
 */
class MainActivity : AudioServiceFragmentActivity() {
    private val CHANNEL = "com.brinsley.kalao/backend"
    private val LARGE_JSON_RESULT_FILE_KEY = "__json_file"
    private val LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES = 256 * 1024
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    internal var backendChannel: MethodChannel? = null
    internal val coreBackend: CoreBackend by lazy { createCoreBackend(applicationContext) }
    internal lateinit var documentPickers: DocumentPickers

    private val nativeBackendMethods = setOf(
        "getAndroidSdkVersion",
        "setScreenAwake",
        "startBackgroundWork",
        "updateBackgroundWork",
        "stopBackgroundWork",
        "readLastCrashReport",
        "clearLastCrashReport",
        "recordAppRuntimeError",
        "createDocument",
        "pickDocumentTree",
        "copyFileToDocument",
        "writeFileToTree",
        "listDocumentTree",
        "deleteDocument",
        "takeSharedFiles",
        "getSupportedAbis",
        "installApk",
    )

    /**
     * Returns [payload] unchanged when it is below the spill threshold,
     * otherwise writes it to a `bridge_json_` cache file and returns
     * `{"__json_file": path}`. Dart reads and deletes the file.
     */
    internal fun bridgeJsonResult(payload: String): Any {
        // UTF-8 size is between length and 3*length, so only the ambiguous
        // band needs the full encode.
        val definitelySmall = payload.length * 3 < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES
        val definitelyLarge = payload.length >= LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES
        if (definitelySmall ||
            (!definitelyLarge &&
                payload.toByteArray(Charsets.UTF_8).size < LARGE_JSON_RESULT_FILE_THRESHOLD_BYTES)
        ) {
            return payload
        }
        return try {
            val file = File(cacheDir, "bridge_json_${System.nanoTime()}.json")
            file.writeText(payload, Charsets.UTF_8)
            mapOf(LARGE_JSON_RESULT_FILE_KEY to file.absolutePath)
        } catch (e: Exception) {
            android.util.Log.w("Kalao", "Failed to spill large bridge JSON result: ${e.message}")
            payload
        }
    }

    // Spill files are deleted after use, but a process kill mid-call orphans
    // them. Sweep leftovers older than an hour from earlier sessions.
    private fun sweepStaleCacheFiles() {
        scope.launch(Dispatchers.IO) {
            try {
                val cutoff = System.currentTimeMillis() - 60 * 60 * 1000L
                cacheDir.listFiles()?.forEach { file ->
                    if (file.isFile && file.lastModified() < cutoff && file.name.startsWith("bridge_json_")) {
                        file.delete()
                    }
                }
            } catch (_: Exception) {}
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Activity-result launchers must exist before the activity starts.
        documentPickers = DocumentPickers(this)
        super.onCreate(savedInstanceState)
        SharedFiles.collect(intent)
    }

    // singleTask: a file opened while Kalao runs arrives here, before
    // onResume, where Dart takes it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        SharedFiles.collect(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Select and initialize the runtime before Flutter can dispatch a call.
        coreBackend
        sweepStaleCacheFiles()

        registerProgressStreams(flutterEngine.dartExecutor.binaryMessenger)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        backendChannel = channel
        channel.setMethodCallHandler { call, result ->
            scope.launch {
                try {
                    if (call.method !in nativeBackendMethods && dispatchBackendApplication(call, result)) {
                        return@launch
                    }
                    when (call.method) {
                        "getAndroidSdkVersion" -> result.success(Build.VERSION.SDK_INT)
                        "setScreenAwake" -> handleSetScreenAwake(call, result)
                        "startBackgroundWork" -> handleStartBackgroundWork(call, result)
                        "updateBackgroundWork" -> handleUpdateBackgroundWork(call, result)
                        "stopBackgroundWork" -> handleStopBackgroundWork(call, result)
                        "readLastCrashReport" -> handleReadLastCrashReport(result)
                        "clearLastCrashReport" -> handleClearLastCrashReport(result)
                        "recordAppRuntimeError" -> handleRecordAppRuntimeError(call, result)
                        "createDocument" -> handleCreateDocument(call, result)
                        "pickDocumentTree" -> handlePickDocumentTree(result)
                        "copyFileToDocument" -> handleCopyFileToDocument(call, result)
                        "writeFileToTree" -> handleWriteFileToTree(call, result)
                        "listDocumentTree" -> handleListDocumentTree(call, result)
                        "deleteDocument" -> handleDeleteDocument(call, result)
                        "getSupportedAbis" -> handleGetSupportedAbis(result)
                        "installApk" -> handleInstallApk(call, result)
                        "takeSharedFiles" -> result.success(
                            withContext(Dispatchers.IO) { SharedFiles.take(applicationContext) },
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error(ForegroundServiceStartPolicy.errorCode(e), e.message, null)
                }
            }
        }
    }

    override fun onDestroy() {
        backendChannel?.setMethodCallHandler(null)
        backendChannel = null
        scope.cancel()
        super.onDestroy()
    }
}
