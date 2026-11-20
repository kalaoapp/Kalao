// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
package com.brinsley.kalao

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

private const val PLAYER_POSITION_STREAM_CHANNEL = "com.brinsley.kalao/player_position_stream"

/**
 * Forwards the engine state Rust publishes (every 33 ms while playing, and
 * right after each command) to Dart as `{state, atMicros}`, where `atMicros`
 * is the CLOCK_MONOTONIC instant the state was taken; Dart interpolates the
 * position from it, so channel delays do not move the lyrics.
 */
internal fun MainActivity.registerProgressStreams(messenger: BinaryMessenger) {
    val main = Handler(Looper.getMainLooper())
    EventChannel(messenger, PLAYER_POSITION_STREAM_CHANNEL).setStreamHandler(
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                val sink = events ?: return
                subscribePlayerState { state, atMicros ->
                    main.post { sink.success(mapOf("state" to state, "atMicros" to atMicros)) }
                }
            }

            override fun onCancel(arguments: Any?) {
                unsubscribePlayerState()
            }
        },
    )
}
