# Feature Specification

Every feature of `poc-webapp` (see `poc-webapp/docs/FEATURES.md`) and every item in `poc-webapp/ROADMAP.md`, redefined for Kalao.

Each feature lists its milestone (see ROADMAP.md). **Source:** P = in the POC, R = POC roadmap, N = new. N items are required by a P or R feature, or are an Android platform requirement.

**Everything is free and on-device.** Nothing is gated by donation or trial, and there are no accounts.

## 1. Playback engine

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 1.1 | Play, pause, seek, volume; gapless track load | P | M1 |
| 1.2 | Original ↔ instrumental switching **without losing position** (both decoded in sync, crossfaded) | P | M1 |
| 1.3 | Vocal-guide mix: blend original/vocal stem and instrumental (0–100% vocal) | N | M1 |
| 1.4 | Key change ±6 semitones; tempo 50–150% without pitch shift | N | M3 |
| 1.5 | Background playback, lock-screen and notification controls, audio focus, headset buttons | N | M1 |
| 1.6 | Formats MP3, M4A/AAC, WAV, FLAC, OGG/Opus | P+ | M1 |
| 1.7 | Local files: import audio from device storage (Storage Access Framework) | N | M1 |
| 1.8 | Streaming playback with range requests from extension-provided sources, plus an offline cache | P | M5 |

## 2. Lyrics

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 2.1 | Per-line layers: Simplified, Traditional, Pinyin, Japanese, Furigana, Romaji, Translation | P | M1 |
| 2.2 | Section breaks and section markers (verse, chorus…), including Chinese markers | P | M1 |
| 2.3 | Automatic pinyin with tone diacritics, er-hua and alternative-bracket rules (POC test cases ported as fixtures) | P | M1 |
| 2.4 | Automatic furigana and romaji for Japanese | N | M3 |
| 2.5 | Traditional ↔ Simplified conversion | N | M3 |
| 2.6 | **Timed lyrics**: line start/end plus optional per-word timing; auto-follow during playback | N (POC TODO) | M2 |
| 2.7 | Manual line stepping (↑/↓, tap a line) as a fallback for untimed lyrics | P | M1 |
| 2.8 | LRC and enhanced-LRC (word-timed) import and export | N | M2 |
| 2.9 | Tap-to-time sync editor (tap at each line or word while playing) | N | M2 |
| 2.10 | Language detection of lyrics | P | M5 |
| 2.11 | Auto lyric fetch through **lyrics extensions** (the private Musixmatch, Genius, Lyrics.ovh, ChartLyrics, utaten, uta-net extensions are made by the owner); ranked to prefer synced lyrics; user-set provider priority and fallback | P+R | M5 |
| 2.12 | Line-by-line translation with **MyMemory**, called directly from the device (no key; an optional contact email raises the free daily limit). Each distinct line is sent once; results are cached per line × language on the device | R | M6 |
| 2.13 | Karaoke word-highlight sweep driven by word timing | N | M2 |

## 3. Modes

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 3.1 | **Learn mode**: original vocals by default, all annotation layers, translation, loop the current line, A–B repeat, slow-down, line stepping | R | M3 |
| 3.2 | **OG Karaoke mode**: instrumental, large timed lyrics with word sweep, countdown before vocals, mic monitoring, scoring, queue. No trial limit | R | M3 |
| 3.3 | Pitch scoring: real-time mic pitch vs. a reference melody extracted from the vocal stem; per-line and total score, pitch-line display | N | M7 |
| 3.4 | Mic monitoring with echo/reverb (wired or USB; Bluetooth latency warning) | N | M7 |
| 3.5 | Record a performance (local only, user-initiated) | N | M8 |

## 4. Stem separation

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 4.1 | **On-device AI stem separation** (vocals / instrumental) for any song, run as a resumable foreground job with a progress notification; results cached | R | M6 |
| 4.2 | In-app model manager: install and delete stem models from a built-in catalogue (not bundled), checksum-verified; choice of default model (fast, balanced or quality) | N | M6 |
| 4.3 | **Optional remote stem processing** on the separate Kalao stem server, using a personal API key (keys are given to donors). The user enters the key in Settings; there is no other app-side donation logic | R | M6 |
| 4.4 | Automatic fallback to on-device if the remote server is unreachable or the key is rejected | N | M6 |

## 5. Extensions

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 5.1 | Extension runtime: sandboxed JavaScript (QuickJS) with declared capabilities: `lyrics`, `metadata`, `audio`, `artwork` | N (Mornye model) | M5 |
| 5.2 | Install from a file (`.kalaoext`) or from an **extension repository URL** (signed index); update checks | N | M5 |
| 5.3 | Extension settings UI generated from the manifest (text, secret, toggle, select, button actions) | N | M5 |
| 5.4 | Per-extension network allowlist, third-party login callback support (for sites an extension talks to), health checks, enable/disable, priority ordering | N | M5 |
| 5.5 | Public extension authoring docs ([EXTENSIONS.md](EXTENSIONS.md)) and a public sample extension (LRCLIB, an open lyrics API) | N | M5 |

## 6. Library and discovery

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 6.1 | Home grid of songs, recently played | P | M1 |
| 6.2 | Search across the local library and all enabled metadata extensions (title, artist, pinyin, romaji) | P | M1/M5 |
| 6.3 | Favorites | P | M4 |
| 6.4 | Song detail and artwork via metadata extensions (replaces the POC's server-side Spotify lookup) | P | M5 |
| 6.5 | Song queue (add, reorder, remove; per-singer in parties) | R | M3 |
| 6.6 | Offline downloads: tracks, stems, lyrics and annotations | N | M5 |
| 6.7 | Stats screen: recent activity, play counts, top songs, scores (replaces the POC dashboard and public-profile stats; local only) | P | M4 |
| 6.8 | **Music folders** (Mornye's local library): folders granted once with SAF are scanned and kept in step with the library — new audio becomes songs (paired with an instrumental and a lyrics file from the same directory), changed files are read again, removed files leave the library. Songs play in place: Kalao only reads the files and never copies, moves or deletes them | N (Mornye) | M4 |

## 7. Backup and restore (replaces accounts and sync)

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 7.1 | **Export** the library to one `.kalaobackup` file in a user-chosen location (SAF): songs, lyrics and timing edits, annotations, favorites, plays and scores, queue, settings, extension list and repositories | N | M4 |
| 7.2 | Optional **media in the backup**: imported audio and stems (large; off by default) | N | M4 |
| 7.3 | **Restore** from a backup: merge into the current library or replace it; a preview of what will change before applying; schema-versioned so newer apps read older backups | N | M4 |
| 7.4 | Optional **scheduled backup** to a chosen folder (daily or weekly, keep the last N), so users can sync that folder with their own tools. A due backup runs when the app is next opened | N | M4 |
| 7.5 | Secrets (stem key, extension secrets, the MyMemory contact email) are **never** written to a backup; restored extensions ask for them again | N | M4 |
| 7.6 | Import from the POC: songs and lyrics from a POC database export, as a one-off converter | N | M4 |

## 8. Parties (LAN only)

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 8.1 | Host a party: the host device plays; guests on the same network join by **QR code** or a short code | R | M8 |
| 8.2 | Guests queue songs from their phones; the host approves or reorders | R | M8 |
| 8.3 | Transport: mDNS discovery plus a WebSocket server on the host; no internet or server | R | M8 |
| 8.4 | Lyrics mirrored on guest phones; scoreboard | N | M8 |
| 8.5 | Cast the lyrics view to a TV | N | M8+ |

## 9. Cross-cutting

| # | Feature | Src | M |
| --- | --- | --- | --- |
| 9.1 | UI languages: en, zh-Hans, zh-Hant, ja at launch; ko, es, fr next; every screen translated | P+R | M1/M6 |
| 9.2 | Themes: dark, light, system, Material You; lyric text sizes S–XXL | P+ | M1 |
| 9.3 | Hardware keyboard and gamepad shortcuts as in the POC (Space, ←/→ 5s, ↑/↓ line, S, L, ?) plus a help sheet | P | M3 |
| 9.4 | Accessibility: TalkBack, dynamic type, contrast, reduced motion | N | M1+ |
| 9.5 | Diagnostics: a local debug log the user can export, and a local crash report shown on the next start with a link to open a GitHub issue. Nothing is sent automatically; no analytics or telemetry | P (replaced) | M4 |
| 9.6 | Privacy statement and open-source licences screens | P+ | M4 |
| 9.7 | **Support Kalao**: one row in Settings → About that opens `https://ko-fi.com/brinsley` in the browser. No popups, banners, reminders or in-app payments | N | M4 |
| 9.8 | Update check against GitHub Releases (on by default, can be turned off): shows the changelog; only when the user taps Update, downloads the APK for the device's ABI, verifies its SHA-256 and opens the system installer. "Open release page" is always offered | N | M4 |

## Dropped or replaced POC items

- **Accounts, Google sign-in, passkeys, roles, bans, profiles, public profiles, account deletion, sync:** dropped. There are no accounts; backup and restore (7.x) moves a library between devices.
- **Admin dashboard, user management, audit log, analytics, GeoIP map, host metrics:** dropped with the account server. The stem server is administered with its own CLI and metrics endpoint.
- **Account tiers, licensing, region limiting (Q10):** dropped.
- **Server song catalog (Q9):** dropped. Content is local or extension-provided.
- **Relayed parties over the internet:** dropped; parties are LAN only.
- **Server-side lyric scraping and the Spotify lookup:** replaced by on-device extensions (5.x).
- **Server-side stem worker as the only option:** on-device is the default; the remote server is optional (4.3).
- **Bare-filename audio in the repo:** replaced by local import, extensions and the download cache.
- **CSP nonces and CSRF tokens:** web-only; they apply to the future `web/` client.
