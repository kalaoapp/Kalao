//! Cancellation for native data jobs. Kotlin acquires a lease per request
//! before queuing the job, so a cancel that arrives before the job starts is
//! still seen. Cancelling an ID with no active lease does nothing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

#[derive(Default)]
struct Entry {
    cancelled: Arc<AtomicBool>,
    leases: usize,
}

type Entries = Arc<Mutex<HashMap<String, Entry>>>;

fn lock(entries: &Entries) -> MutexGuard<'_, HashMap<String, Entry>> {
    entries.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Default, uniffi::Object)]
pub struct CancellationRegistry {
    entries: Entries,
}

#[uniffi::export]
impl CancellationRegistry {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    /// A lease for request `id`; several leases may share an ID.
    pub fn acquire(&self, id: String) -> Arc<RequestLease> {
        let mut entries = lock(&self.entries);
        let entry = entries.entry(id.clone()).or_default();
        entry.leases += 1;
        Arc::new(RequestLease {
            entries: Arc::clone(&self.entries),
            id,
            cancelled: Arc::clone(&entry.cancelled),
            released: AtomicBool::new(false),
        })
    }

    /// Cancels every active lease for `id`.
    pub fn cancel(&self, id: String) {
        if let Some(entry) = lock(&self.entries).get(&id) {
            entry.cancelled.store(true, Ordering::Release);
        }
    }
}

#[derive(uniffi::Object)]
pub struct RequestLease {
    entries: Entries,
    id: String,
    cancelled: Arc<AtomicBool>,
    released: AtomicBool,
}

#[uniffi::export]
impl RequestLease {
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Ends this lease once; a later request with the same ID starts fresh.
    pub fn release(&self) {
        if self.released.swap(true, Ordering::AcqRel) {
            return;
        }
        let mut entries = lock(&self.entries);
        if let Some(entry) = entries.get_mut(&self.id) {
            entry.leases = entry.leases.saturating_sub(1);
            if entry.leases == 0 {
                entries.remove(&self.id);
            }
        }
    }
}

impl Drop for RequestLease {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_reaches_active_leases_only_and_retries_start_fresh() {
        let registry = CancellationRegistry::new();
        registry.cancel("job".into());
        let first = registry.acquire("job".into());
        let second = registry.acquire("job".into());
        assert!(!first.is_cancelled());
        registry.cancel("job".into());
        assert!(first.is_cancelled() && second.is_cancelled());
        first.release();
        first.release();
        assert!(second.is_cancelled());
        second.release();
        let retry = registry.acquire("job".into());
        assert!(!retry.is_cancelled());
        drop(first);
        drop(second);
        assert!(!retry.is_cancelled());
        assert!(!registry.acquire("other".into()).is_cancelled());
    }
}
