// Login redirects for extensions (EXTENSIONS.md §3, `auth.callbackPath`): a
// site sends the browser to `kalao://ext/<id>/<path>?…`, Android opens Kalao,
// and Dart takes the URLs on resume and hands them to the extension runtime.
package com.brinsley.kalao

import android.content.Intent

internal object ExtensionAuthCallbacks {
    private val pending = mutableListOf<String>()

    /** Remembers an extension callback URL from a VIEW [intent]. */
    @Synchronized
    fun collect(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || uri.scheme != "kalao" || uri.host != "ext") return
        pending += uri.toString()
        // Handled once: a recreated activity must not deliver it again.
        intent.action = Intent.ACTION_MAIN
    }

    @Synchronized
    fun take(): List<String> = pending.toList().also { pending.clear() }
}
