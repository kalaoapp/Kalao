// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
package com.brinsley.kalao

import android.content.Context
import com.brinsley.kalao.backend.PlayerStateSink
import com.brinsley.kalao.backend.invokeApplication as rustInvokeApplication
import com.brinsley.kalao.backend.playerSubscribe
import com.brinsley.kalao.backend.playerUnsubscribe
import com.brinsley.kalao.backend.runNativeDataJob
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The backend that answers every channel method Kotlin does not handle itself. */
internal interface CoreBackend {
    val implementation: String

    /** [arguments] is the channel's argument value; the reply is JSON text. */
    fun invokeApplication(method: String, arguments: Any?): String
}

internal fun createCoreBackend(context: Context): CoreBackend = RustCoreBackend.initialize(context)

/**
 * Runs a Rust method on Dispatchers.IO and replies with its JSON text (or a
 * `__json_file` spill map for large replies). Data jobs get a cancellation
 * lease acquired before the call is queued, so a following
 * `cancelNativeDataJob` also reaches work that has not started.
 */
internal suspend fun MainActivity.dispatchBackendApplication(call: MethodCall, result: MethodChannel.Result): Boolean {
    if (call.method == "cancelNativeDataJob") {
        NativeDataJobs.cancel(call.argument<String>("request_id") ?: "")
        result.success(null)
        return true
    }
    val jobId = if (call.method == "runNativeDataJob") {
        call.argument<String>("request_id") ?: error("Missing data job ID")
    } else {
        null
    }
    val jobLease = jobId?.let { NativeDataJobs.acquire(it) }
    val response = try {
        withContext(Dispatchers.IO) {
            if (jobLease != null) {
                val request = call.argument<String>("request_json") ?: error("Missing data job request")
                runNativeDataJob(request, jobLease)
            } else {
                coreBackend.invokeApplication(call.method, call.arguments)
            }
        }
    } finally {
        if (jobLease != null) NativeDataJobs.release(jobLease)
    }
    result.success(bridgeJsonResult(response))
    return true
}

internal object RustCoreBackend : CoreBackend {
    override val implementation = "rust"
    @Volatile private var initialized = false

    @Synchronized
    fun initialize(context: Context): RustCoreBackend {
        if (!initialized) {
            // Load the library now so a missing or broken .so fails at startup,
            // not on the first user action.
            rustInvokeApplication("initBackend", "{}")
            initialized = true
        }
        return this
    }

    /** Dart sends the arguments of Rust methods as JSON text. */
    override fun invokeApplication(method: String, arguments: Any?): String =
        rustInvokeApplication(
            method,
            when (arguments) {
                null -> "{}"
                is String -> arguments
                else -> error("Arguments of $method must be JSON text")
            },
        )
}

/**
 * Sends each engine state Rust publishes to [deliver], with the
 * `System.nanoTime()` (CLOCK_MONOTONIC) instant it was published, in
 * microseconds. Replaces any earlier subscriber.
 */
internal fun subscribePlayerState(deliver: (state: String, atMicros: Long) -> Unit) {
    playerSubscribe(
        object : PlayerStateSink {
            override fun onState(stateJson: String) = deliver(stateJson, System.nanoTime() / 1000)
        },
    )
}

internal fun unsubscribePlayerState() = playerUnsubscribe()
