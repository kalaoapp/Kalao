// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
//! Files the app lends by descriptor (ADR-018). Music-folder documents reach
//! Rust as `/proc/self/fd/N` paths. Reopening such a path issues a new open
//! through the storage provider, which Android refuses for documents read
//! through Storage Access Framework (`Permission denied`, and always for
//! AppFuse proxies), so the descriptor is duplicated instead, as Mornye's
//! `open_audio_file` does.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

/// The descriptor number of a lent path (`/proc/self/fd/N` or `/dev/fd/N`).
pub fn lent_descriptor(path: &Path) -> Option<i32> {
    let path = path.to_str()?;
    path.strip_prefix("/proc/self/fd/")
        .or_else(|| path.strip_prefix("/dev/fd/"))?
        .parse::<i32>()
        .ok()
        .filter(|descriptor| *descriptor >= 0)
}

/// A file opened for reading with its own position. Duplicated descriptors
/// share one file offset, and playback and the loop pre-decode read the same
/// lent path at once, so reads are positional and never move the offset.
#[derive(Debug)]
pub struct LentFile {
    file: File,
    position: u64,
    len: Option<u64>,
}

impl LentFile {
    pub fn len(&self) -> Option<u64> {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == Some(0)
    }
}

/// Opens `path` for reading. A lent descriptor is duplicated: the copy stays
/// valid whatever the app does with its own descriptor.
pub fn open_lent(path: &Path) -> io::Result<LentFile> {
    let file = open_file(path)?;
    let len = file
        .metadata()
        .ok()
        .filter(|m| m.is_file())
        .map(|m| m.len());
    Ok(LentFile {
        file,
        position: 0,
        len,
    })
}

fn open_file(path: &Path) -> io::Result<File> {
    #[cfg(unix)]
    if let Some(descriptor) = lent_descriptor(path) {
        use std::os::fd::BorrowedFd;
        // The app keeps the descriptor open until it closes the lease, which
        // is after this call returns.
        #[allow(unsafe_code)]
        let borrowed = unsafe { BorrowedFd::borrow_raw(descriptor) };
        return Ok(File::from(borrowed.try_clone_to_owned()?));
    }
    File::open(path)
}

impl Read for LentFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = read_at(&self.file, buf, self.position)?;
        self.position += read as u64;
        Ok(read)
    }
}

#[cfg(unix)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::unix::fs::FileExt::read_at(file, buf, offset)
}

#[cfg(windows)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::windows::fs::FileExt::seek_read(file, buf, offset)
}

impl Seek for LentFile {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let target = match to {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::Current(delta) => self.position.checked_add_signed(delta),
            SeekFrom::End(delta) => {
                let len = match self.len {
                    Some(len) => len,
                    None => self.file.metadata()?.len(),
                };
                len.checked_add_signed(delta)
            }
        };
        self.position = target
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "seek before the start"))?;
        Ok(self.position)
    }
}

impl symphonia::core::io::MediaSource for LentFile {
    fn is_seekable(&self) -> bool {
        self.len.is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.len
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("kalao-lent-{name}"));
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn descriptor_paths_are_recognised() {
        assert_eq!(lent_descriptor(Path::new("/proc/self/fd/42")), Some(42));
        assert_eq!(lent_descriptor(Path::new("/dev/fd/7")), Some(7));
        for path in [
            "/proc/self/fd/-1",
            "/proc/self/fd/x",
            "/music/a.flac",
            "fd/3",
        ] {
            assert_eq!(lent_descriptor(Path::new(path)), None, "{path}");
        }
    }

    #[test]
    fn plain_paths_read_and_seek() {
        let path = temp("plain.txt", b"abcdef");
        let mut file = open_lent(&path).unwrap();
        assert_eq!(file.len(), Some(6));
        let mut head = [0; 2];
        file.read_exact(&mut head).unwrap();
        assert_eq!(&head, b"ab");
        file.seek(SeekFrom::End(-2)).unwrap();
        let mut tail = String::new();
        file.read_to_string(&mut tail).unwrap();
        assert_eq!(tail, "ef");
        assert!(file.seek(SeekFrom::Current(-10)).is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn lent_descriptors_are_duplicated_with_their_own_positions() {
        use std::os::fd::AsRawFd;
        let path = temp("fd.txt", b"0123456789");
        let lent = File::open(&path).unwrap();
        let lent_path = format!("/proc/self/fd/{}", lent.as_raw_fd());
        let mut first = open_lent(Path::new(&lent_path)).unwrap();
        let mut second = open_lent(Path::new(&lent_path)).unwrap();
        let mut a = [0; 4];
        first.read_exact(&mut a).unwrap();
        let mut b = [0; 3];
        second.read_exact(&mut b).unwrap();
        assert_eq!((&a, &b), (b"0123", b"012"));
        drop(lent);
        // The copies outlive the lent descriptor.
        first.read_exact(&mut a).unwrap();
        assert_eq!(&a, b"4567");
        std::fs::remove_file(path).unwrap();
    }
}
