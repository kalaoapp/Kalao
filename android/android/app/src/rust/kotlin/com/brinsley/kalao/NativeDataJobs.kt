// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
package com.brinsley.kalao

import com.brinsley.kalao.backend.CancellationRegistry
import com.brinsley.kalao.backend.RequestLease

/**
 * Leases for native data jobs. A lease is acquired before the job is queued on
 * IO, so a `cancelNativeDataJob` that follows on the channel also reaches work
 * that has not started; cancelling an ID with no active job does nothing.
 */
internal object NativeDataJobs {
    private val registry = CancellationRegistry()

    fun acquire(id: String): RequestLease = registry.acquire(id)

    fun cancel(id: String) = registry.cancel(id)

    fun release(lease: RequestLease) {
        try {
            lease.release()
        } finally {
            lease.close()
        }
    }
}
