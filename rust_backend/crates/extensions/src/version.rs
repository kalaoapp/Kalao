//! Semantic versions for manifests, `minKalao` and repository updates.

use std::cmp::Ordering;
use std::fmt;

/// `major.minor.patch` with an optional pre-release (`1.2.0-beta.1`).
/// Build metadata (`+…`) is accepted and ignored, as semver orders it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    pub pre: Vec<String>,
}

impl Version {
    pub fn parse(input: &str) -> Option<Self> {
        let input = input.trim();
        let core_and_pre = input.split('+').next()?;
        let (core, pre) = match core_and_pre.split_once('-') {
            Some((core, pre)) => (core, Some(pre)),
            None => (core_and_pre, None),
        };
        let mut parts = core.split('.');
        let mut number = || -> Option<u64> {
            let part = parts.next()?;
            if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            if part.len() > 1 && part.starts_with('0') {
                return None;
            }
            part.parse().ok()
        };
        let (major, minor, patch) = (number()?, number()?, number()?);
        if parts.next().is_some() {
            return None;
        }
        let pre = match pre {
            Some(pre) => {
                let identifiers: Vec<String> = pre.split('.').map(str::to_owned).collect();
                if identifiers.iter().any(|identifier| {
                    identifier.is_empty()
                        || !identifier
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                }) {
                    return None;
                }
                identifiers
            }
            None => Vec::new(),
        };
        Some(Self {
            major,
            minor,
            patch,
            pre,
        })
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(other.major, other.minor, other.patch))
            .then_with(|| match (self.pre.is_empty(), other.pre.is_empty()) {
                (true, true) => Ordering::Equal,
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                (false, false) => compare_pre(&self.pre, &other.pre),
            })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn compare_pre(first: &[String], second: &[String]) -> Ordering {
    for (a, b) in first.iter().zip(second) {
        let ordering = match (a.parse::<u64>(), b.parse::<u64>()) {
            (Ok(a), Ok(b)) => a.cmp(&b),
            (Ok(_), Err(_)) => Ordering::Less,
            (Err(_), Ok(_)) => Ordering::Greater,
            (Err(_), Err(_)) => a.cmp(b),
        };
        if ordering != Ordering::Equal {
            return ordering;
        }
    }
    first.len().cmp(&second.len())
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if !self.pre.is_empty() {
            write!(f, "-{}", self.pre.join("."))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(text: &str) -> Version {
        Version::parse(text).expect(text)
    }

    #[test]
    fn parses_and_orders_as_semver() {
        assert!(v("1.2.0") > v("1.1.9"));
        assert!(v("1.0.0") > v("1.0.0-rc.1"));
        assert!(v("1.0.0-beta.11") > v("1.0.0-beta.2"));
        assert!(v("1.0.0-beta") > v("1.0.0-alpha.1"));
        assert_eq!(v("1.0.0+build.5"), v("1.0.0"));
        assert_eq!(v("0.10.3").to_string(), "0.10.3");
    }

    #[test]
    fn rejects_malformed_versions() {
        for text in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.x.3",
            "1.2.3-",
            "1.2.3-a..b",
        ] {
            assert!(Version::parse(text).is_none(), "{text}");
        }
    }
}
