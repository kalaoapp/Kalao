// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.
//! Files the Android host lends as descriptors (ADR-018).

use std::fs::File;
use std::io;
use std::path::Path;

/// Opens `path` for reading. A descriptor path the host lent
/// (`/proc/self/fd/N`, `/dev/fd/N`, a music-folder file) is duplicated
/// instead of reopened: Android refuses to reopen an AppFuse-proxied
/// descriptor, and the copy stays readable and seekable on its own. The host
/// keeps the lent descriptor open until the song is replaced.
pub fn open_file(path: &Path) -> io::Result<File> {
    #[cfg(unix)]
    if let Some(descriptor) = lent_descriptor(path) {
        use std::os::fd::BorrowedFd;
        // The one unsafe call in the workspace (ADR-018): the host owns the
        // descriptor and keeps it open for the whole call.
        #[allow(unsafe_code)]
        let owned = unsafe { BorrowedFd::borrow_raw(descriptor) }.try_clone_to_owned()?;
        return Ok(File::from(owned));
    }
    File::open(path)
}

/// The descriptor number of a lent path.
#[cfg_attr(not(unix), allow(dead_code))]
fn lent_descriptor(path: &Path) -> Option<i32> {
    let text = path.to_str()?;
    text.strip_prefix("/proc/self/fd/")
        .or_else(|| text.strip_prefix("/dev/fd/"))?
        .parse::<i32>()
        .ok()
        .filter(|descriptor| *descriptor >= 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_paths_are_recognised() {
        assert_eq!(lent_descriptor(Path::new("/proc/self/fd/7")), Some(7));
        assert_eq!(lent_descriptor(Path::new("/dev/fd/12")), Some(12));
        assert_eq!(lent_descriptor(Path::new("/proc/self/fd/-1")), None);
        assert_eq!(lent_descriptor(Path::new("/proc/self/fd/x")), None);
        assert_eq!(lent_descriptor(Path::new("/music/a.flac")), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_lent_descriptor_is_duplicated_and_readable() {
        use std::io::{Read, Seek, SeekFrom, Write};
        use std::os::fd::AsRawFd;
        let dir = std::env::temp_dir().join(format!("kalao-lent-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("song.txt");
        std::fs::File::create(&path)
            .unwrap()
            .write_all(b"lent bytes")
            .unwrap();
        let lent = File::open(&path).unwrap();
        let mut copy =
            open_file(Path::new(&format!("/proc/self/fd/{}", lent.as_raw_fd()))).unwrap();
        let mut text = String::new();
        copy.read_to_string(&mut text).unwrap();
        assert_eq!(text, "lent bytes");
        copy.seek(SeekFrom::Start(5)).unwrap();
        drop(lent);
        let mut rest = String::new();
        copy.read_to_string(&mut rest).unwrap();
        assert_eq!(rest, "bytes");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
