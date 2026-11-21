//! Streaming playback of what an extension's `resolveAudio` returned
//! (FEATURES 1.8): one downloader thread per source fills a cache file from
//! an HTTP response (`Range: bytes=<offset>-`), and every decoder reads it
//! through its own handle, waiting for bytes that have not arrived. A seek
//! past the downloaded part restarts the download there when the server
//! honours ranges. A finished download becomes `<key>.data` and later plays
//! as a plain file; the cache keeps the newest downloads up to a byte limit.

use kalao_audio::{Media, StreamOpener};
use kalao_network::{HttpRequest, NetworkSession};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime};

/// How far ahead of the download a reader may wait before the download
/// restarts at the reader's position.
const RESTART_DISTANCE: u64 = 1 << 20;
/// A reader gives up after waiting this long for bytes.
const READ_WAIT: Duration = Duration::from_secs(30);
const RETRIES: u32 = 3;
pub const CACHE_LIMIT_BYTES: u64 = 1 << 30;

/// One HTTP response body from `offset`.
pub trait Body: Send {
    /// Whether the server answered the range (206); otherwise the body
    /// starts at byte 0.
    fn partial(&self) -> bool;
    /// The full length of the resource, if the server said.
    fn total(&self) -> Option<u64>;
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, String>;
}

pub trait Origin: Send + Sync {
    fn open(&self, offset: u64) -> Result<Box<dyn Body>, String>;
}

#[derive(Default)]
struct State {
    /// Downloaded byte ranges, sorted and merged.
    ranges: Vec<(u64, u64)>,
    total: Option<u64>,
    /// Where the downloader is writing.
    cursor: u64,
    /// The position a reader is waiting for.
    want: Option<u64>,
    restart: bool,
    ranges_supported: bool,
    complete: bool,
    error: Option<String>,
}

impl State {
    fn has(&self, position: u64) -> bool {
        self.ranges
            .iter()
            .any(|(start, end)| *start <= position && position < *end)
    }

    fn add(&mut self, start: u64, end: u64) {
        self.ranges.push((start, end));
        self.ranges.sort_unstable();
        let mut merged: Vec<(u64, u64)> = Vec::with_capacity(self.ranges.len());
        for (start, end) in self.ranges.drain(..) {
            match merged.last_mut() {
                Some(last) if start <= last.1 => last.1 = last.1.max(end),
                _ => merged.push((start, end)),
            }
        }
        self.ranges = merged;
    }

    /// The first missing byte at or after `from`, wrapping to the start.
    fn next_missing(&self, from: u64) -> Option<u64> {
        let total = self.total?;
        let after = |from: u64| {
            let mut position = from;
            for (start, end) in &self.ranges {
                if *start <= position && position < *end {
                    position = *end;
                }
            }
            (position < total).then_some(position)
        };
        after(from).or_else(|| after(0))
    }
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    closed: AtomicBool,
    part: PathBuf,
    data: PathBuf,
    extension: Option<String>,
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        // Every reader is gone: keep a finished download, drop a partial one.
        let complete = self.state().complete;
        if complete && std::fs::rename(&self.part, &self.data).is_ok() {
            return;
        }
        let _ = std::fs::remove_file(&self.part);
    }
}

/// The decoders' view of one stream. Dropping the last opener (the engine
/// loaded another song) stops the download.
pub struct HttpStreamOpener {
    shared: Arc<Shared>,
}

impl Drop for HttpStreamOpener {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.changed.notify_all();
    }
}

impl StreamOpener for HttpStreamOpener {
    fn open(&self) -> io::Result<Box<dyn kalao_audio::MediaSource>> {
        Ok(Box::new(Reader {
            file: File::open(&self.shared.part)?,
            shared: self.shared.clone(),
            position: 0,
        }))
    }

    fn extension(&self) -> Option<&str> {
        self.shared.extension.as_deref()
    }
}

struct Reader {
    // Closed before `shared` drops: renaming the finished file needs every
    // handle closed on Windows.
    file: File,
    shared: Arc<Shared>,
    position: u64,
}

impl Reader {
    /// Waits until `position` is downloaded (true) or past the end (false).
    fn wait_for(&self, position: u64) -> io::Result<bool> {
        let started = Instant::now();
        let mut state = self.shared.state();
        loop {
            if state.has(position) {
                return Ok(true);
            }
            if state.total.is_some_and(|total| position >= total) {
                return Ok(false);
            }
            if let Some(error) = &state.error {
                return Err(io::Error::other(error.clone()));
            }
            if self.shared.closed.load(Ordering::Acquire) {
                return Err(io::Error::other("stream closed"));
            }
            let elapsed = started.elapsed();
            if elapsed >= READ_WAIT {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "stream stalled"));
            }
            state.want = Some(position);
            let far = position < state.cursor || position > state.cursor + RESTART_DISTANCE;
            if far && state.ranges_supported && !state.restart {
                state.restart = true;
                self.shared.changed.notify_all();
            }
            state = self
                .shared
                .changed
                .wait_timeout(state, (READ_WAIT - elapsed).min(Duration::from_millis(250)))
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl Read for Reader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() || !self.wait_for(self.position)? {
            return Ok(0);
        }
        let available = {
            let state = self.shared.state();
            state
                .ranges
                .iter()
                .find(|(start, end)| *start <= self.position && self.position < *end)
                .map_or(0, |(_, end)| end - self.position)
        };
        let count = buffer.len().min(available as usize);
        self.file.seek(SeekFrom::Start(self.position))?;
        let read = self.file.read(&mut buffer[..count])?;
        self.position += read as u64;
        Ok(read)
    }
}

impl Seek for Reader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(offset) => offset as i128,
            SeekFrom::Current(delta) => self.position as i128 + delta as i128,
            SeekFrom::End(delta) => {
                let total = self.shared.state().total.ok_or_else(|| {
                    io::Error::new(io::ErrorKind::Unsupported, "stream length unknown")
                })?;
                total as i128 + delta as i128
            }
        };
        if target < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek before start",
            ));
        }
        self.position = target as u64;
        Ok(self.position)
    }
}

impl kalao_audio::MediaSource for Reader {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.shared.state().total
    }
}

/// Starts streaming `origin` into `cache_dir/<key>.part`.
pub fn start(
    origin: Arc<dyn Origin>,
    cache_dir: &Path,
    key: &str,
    extension: Option<String>,
) -> io::Result<Arc<HttpStreamOpener>> {
    std::fs::create_dir_all(cache_dir)?;
    let part = cache_dir.join(format!("{key}.part"));
    let data = cache_dir.join(format!("{key}.data"));
    let file = File::create(&part)?;
    let shared = Arc::new(Shared {
        state: Mutex::default(),
        changed: Condvar::new(),
        closed: AtomicBool::new(false),
        part,
        data,
        extension,
    });
    let worker = shared.clone();
    std::thread::Builder::new()
        .name("kalao-stream".into())
        .spawn(move || download(&worker, origin.as_ref(), file))?;
    Ok(Arc::new(HttpStreamOpener { shared }))
}

fn download(shared: &Shared, origin: &dyn Origin, mut file: File) {
    let mut offset = 0u64;
    let mut failures = 0;
    let mut buffer = vec![0u8; 64 << 10];
    'open: while !shared.closed.load(Ordering::Acquire) {
        let mut body = match origin.open(offset) {
            Ok(body) => body,
            Err(error) => {
                failures += 1;
                if failures >= RETRIES {
                    shared.state().error = Some(error);
                    shared.changed.notify_all();
                    return;
                }
                std::thread::sleep(Duration::from_millis(300 * u64::from(failures)));
                continue;
            }
        };
        {
            let mut state = shared.state();
            if !body.partial() {
                // The server ignored the range: the body starts at 0.
                offset = 0;
                state.ranges_supported = false;
            } else {
                state.ranges_supported = true;
            }
            if state.total.is_none() {
                state.total = body.total();
            }
            state.cursor = offset;
            state.restart = false;
        }
        shared.changed.notify_all();
        loop {
            if shared.closed.load(Ordering::Acquire) {
                return;
            }
            let count = match body.read(&mut buffer) {
                Ok(count) => count,
                Err(error) => {
                    failures += 1;
                    if failures >= RETRIES {
                        shared.state().error = Some(error);
                        shared.changed.notify_all();
                        return;
                    }
                    continue 'open;
                }
            };
            if count == 0 {
                break;
            }
            failures = 0;
            if file
                .seek(SeekFrom::Start(offset))
                .and_then(|_| file.write_all(&buffer[..count]))
                .is_err()
            {
                shared.state().error = Some("cannot write the stream cache".into());
                shared.changed.notify_all();
                return;
            }
            let mut state = shared.state();
            state.add(offset, offset + count as u64);
            offset += count as u64;
            state.cursor = offset;
            let restart = state.restart && state.ranges_supported;
            let resume_at = state.want.and_then(|want| state.next_missing(want));
            drop(state);
            shared.changed.notify_all();
            if restart && let Some(position) = resume_at {
                offset = position;
                continue 'open;
            }
        }
        let mut state = shared.state();
        if state.total.is_none() {
            // No length from the server: what arrived is the whole file.
            state.total = Some(offset);
        }
        match state.next_missing(state.want.unwrap_or(0)) {
            Some(position) if state.ranges_supported => {
                offset = position;
                drop(state);
                shared.changed.notify_all();
            }
            Some(_) => {
                state.error = Some("the stream ended early".into());
                drop(state);
                shared.changed.notify_all();
                return;
            }
            None => {
                state.complete = true;
                drop(state);
                let _ = file.flush();
                shared.changed.notify_all();
                return;
            }
        }
    }
}

/// HTTP through the extension's own network session (allowlist, cookies).
pub struct SessionOrigin {
    pub session: Arc<NetworkSession>,
    pub url: String,
    pub headers: BTreeMap<String, String>,
}

pub struct SessionBody {
    stream: kalao_network::HttpStream,
    partial: bool,
    total: Option<u64>,
}

impl Body for SessionBody {
    fn partial(&self) -> bool {
        self.partial
    }

    fn total(&self) -> Option<u64> {
        self.total
    }

    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, String> {
        self.stream.read(buffer, || Ok(()))
    }
}

fn header<'a>(headers: &'a BTreeMap<String, Vec<String>>, name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .and_then(|(_, values)| values.first())
        .map(String::as_str)
}

/// `bytes 0-99/1234` → 1234.
fn content_range_total(value: &str) -> Option<u64> {
    value.rsplit('/').next()?.trim().parse().ok()
}

impl SessionOrigin {
    /// Opens the URL from `offset`; also used for whole downloads.
    pub fn open_stream(
        &self,
        offset: u64,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<SessionBody, String> {
        let mut headers = self.headers.clone();
        headers.insert("Range".into(), format!("bytes={offset}-"));
        let stream = self.session.open_stream(
            HttpRequest {
                url: self.url.clone(),
                method: "GET".into(),
                body: String::new(),
                headers,
                default_json: false,
                user_agent: "Kalao/1.0".into(),
            },
            Duration::from_secs(3600),
            Duration::from_secs(30),
            check,
        )?;
        let status = stream.response.status;
        if !(200..300).contains(&status) {
            return Err(format!("the audio host answered HTTP {status}"));
        }
        let partial = status == 206;
        let total = if partial {
            header(&stream.response.headers, "content-range").and_then(content_range_total)
        } else {
            header(&stream.response.headers, "content-length").and_then(|v| v.trim().parse().ok())
        };
        Ok(SessionBody {
            stream,
            partial,
            total,
        })
    }
}

impl Origin for SessionOrigin {
    fn open(&self, offset: u64) -> Result<Box<dyn Body>, String> {
        Ok(Box::new(self.open_stream(offset, &|| Ok(()))?))
    }
}

/// A finished download for `key`, if cached.
pub fn cached(cache_dir: &Path, key: &str) -> Option<PathBuf> {
    let path = cache_dir.join(format!("{key}.data"));
    if path.is_file() {
        // Touch it so the cache keeps recently played songs.
        let _ = File::options()
            .append(true)
            .open(&path)
            .and_then(|file| file.set_modified(SystemTime::now()));
        Some(path)
    } else {
        None
    }
}

/// Deletes the oldest finished downloads beyond `limit` bytes and partial
/// files left by an earlier run.
pub fn sweep(cache_dir: &Path, limit: u64) {
    let Ok(entries) = std::fs::read_dir(cache_dir) else {
        return;
    };
    let mut data = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        match path.extension().and_then(|ext| ext.to_str()) {
            Some("data") => data.push((
                meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                meta.len(),
                path,
            )),
            Some("part") => {
                let stale = meta
                    .modified()
                    .ok()
                    .and_then(|time| time.elapsed().ok())
                    .is_some_and(|age| age > Duration::from_secs(6 * 3600));
                if stale {
                    let _ = std::fs::remove_file(path);
                }
            }
            _ => {}
        }
    }
    data.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    let mut used = 0;
    for (_, size, path) in data {
        used += size;
        if used > limit {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Cache keys come from Dart (a hash of extension, track and kind); keep
/// them to safe file names.
pub fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The media for one resolved source: the cached file when the download
/// finished before, else a new stream.
pub fn media(
    origin: Arc<dyn Origin>,
    cache_dir: &Path,
    key: &str,
    extension: Option<String>,
) -> io::Result<Media> {
    if let Some(path) = cached(cache_dir, key) {
        return Ok(Media::File(path));
    }
    sweep(cache_dir, CACHE_LIMIT_BYTES);
    Ok(Media::Stream(start(origin, cache_dir, key, extension)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Memory {
        bytes: Vec<u8>,
        ranges: bool,
        opens: Mutex<Vec<u64>>,
        chunk: usize,
    }

    struct MemoryBody {
        bytes: Vec<u8>,
        position: usize,
        partial: bool,
        total: u64,
        chunk: usize,
    }

    impl Body for MemoryBody {
        fn partial(&self) -> bool {
            self.partial
        }
        fn total(&self) -> Option<u64> {
            Some(self.total)
        }
        fn read(&mut self, buffer: &mut [u8]) -> Result<usize, String> {
            std::thread::sleep(Duration::from_millis(1));
            let count = buffer
                .len()
                .min(self.chunk)
                .min(self.bytes.len() - self.position);
            buffer[..count].copy_from_slice(&self.bytes[self.position..self.position + count]);
            self.position += count;
            Ok(count)
        }
    }

    impl Origin for Memory {
        fn open(&self, offset: u64) -> Result<Box<dyn Body>, String> {
            self.opens.lock().unwrap().push(offset);
            let start = if self.ranges { offset as usize } else { 0 };
            Ok(Box::new(MemoryBody {
                bytes: self.bytes[start..].to_vec(),
                position: 0,
                partial: self.ranges,
                total: self.bytes.len() as u64,
                chunk: self.chunk,
            }))
        }
    }

    fn dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kalao-stream-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn data(size: usize) -> Vec<u8> {
        (0..size).map(|i| (i * 31 % 251) as u8).collect()
    }

    #[test]
    fn readers_see_the_bytes_and_a_far_seek_restarts_the_download() {
        let cache = dir("ranges");
        let bytes = data(4 << 20);
        let origin = Arc::new(Memory {
            bytes: bytes.clone(),
            ranges: true,
            opens: Mutex::default(),
            chunk: 16 << 10,
        });
        let opener = start(origin.clone(), &cache, "k1", Some("mp3".into())).unwrap();
        let mut reader = opener.open().unwrap();
        let mut head = vec![0; 1000];
        reader.read_exact(&mut head).unwrap();
        assert_eq!(head, bytes[..1000]);
        // Far ahead of the download: it restarts there.
        let far = 3 << 20;
        reader.seek(SeekFrom::Start(far)).unwrap();
        let mut piece = vec![0; 5000];
        reader.read_exact(&mut piece).unwrap();
        assert_eq!(piece, bytes[far as usize..far as usize + 5000]);
        assert!(
            origin
                .opens
                .lock()
                .unwrap()
                .iter()
                .any(|offset| *offset >= far)
        );
        // The rest fills in; a full read matches.
        let mut all = Vec::new();
        reader.seek(SeekFrom::Start(0)).unwrap();
        reader.read_to_end(&mut all).unwrap();
        assert_eq!(all, bytes);
        assert_eq!(reader.byte_len(), Some(bytes.len() as u64));
        drop(reader);
        drop(opener);
        // Finished: kept as a plain file for the next play.
        let deadline = Instant::now() + Duration::from_secs(5);
        while cached(&cache, "k1").is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(std::fs::read(cached(&cache, "k1").unwrap()).unwrap(), bytes);
        let _ = std::fs::remove_dir_all(cache);
    }

    #[test]
    fn servers_without_ranges_stream_from_the_start() {
        let cache = dir("noranges");
        let bytes = data(300_000);
        let origin = Arc::new(Memory {
            bytes: bytes.clone(),
            ranges: false,
            opens: Mutex::default(),
            chunk: 64 << 10,
        });
        let opener = start(origin.clone(), &cache, "k2", None).unwrap();
        let mut reader = opener.open().unwrap();
        reader.seek(SeekFrom::Start(200_000)).unwrap();
        let mut piece = vec![0; 1000];
        reader.read_exact(&mut piece).unwrap();
        assert_eq!(piece, bytes[200_000..201_000]);
        assert_eq!(*origin.opens.lock().unwrap(), [0]);
        drop(reader);
        drop(opener);
        let _ = std::fs::remove_dir_all(cache);
    }

    #[test]
    fn the_cache_keeps_the_newest_downloads() {
        let cache = dir("sweep");
        std::fs::create_dir_all(&cache).unwrap();
        for (index, name) in ["old", "mid", "new"].iter().enumerate() {
            let path = cache.join(format!("{name}.data"));
            std::fs::write(&path, vec![0u8; 100]).unwrap();
            let time = SystemTime::now() - Duration::from_secs(1000 - index as u64 * 100);
            File::options()
                .append(true)
                .open(&path)
                .unwrap()
                .set_modified(time)
                .unwrap();
        }
        sweep(&cache, 250);
        assert!(!cache.join("old.data").exists());
        assert!(cache.join("mid.data").exists() && cache.join("new.data").exists());
        assert!(valid_key("abc_1-2") && !valid_key("../x") && !valid_key(""));
        assert_eq!(content_range_total("bytes 0-99/1234"), Some(1234));
        let _ = std::fs::remove_dir_all(cache);
    }
}
