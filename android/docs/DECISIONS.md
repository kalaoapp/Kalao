# Decisions

## Owner decisions (2026-11-15)

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Backend | **Rust.** Originally a Rust account server; superseded by Q13: there is no account server. The only server is the optional stem server (Rust gateway) |
| Q2 | Identity | Product **Kalao** (ka-la-oh); application ID **`com.brinsley.kalao`** |
| Q3 | Content sourcing / scraping | **Mornye-style extensions.** All scrapers are user-installable extensions made by the owner, kept **private**, never in the public repo. The extension framework and the authoring docs are public (EXTENSIONS.md) |
| Q4 | Stem separation | **On-device** by default. A separate **stem server** (Docker) accepts unique, 1-device-limited API keys, which are given to donors. No paywall, and no in-app donation checks |
| Q5 | Translation | Superseded by Q12: **MyMemory only** |
| Q6 | Repo layout | `desktop/` and `web/` get their own top-level folders, separate from `poc-webapp/` |
| Q7 | Pricing | **None.** One non-intrusive "Support Kalao" link; no popups or prompts. Tiers and licensing from the POC roadmap are dropped |
| Q8 | Shared Rust code | **Mornye's `rust_backend/` template**, at the top level (`karaoke/rust_backend/`), shared by `android/`, `desktop/` and `web/` (ARCHITECTURE.md §4) |
| Q9 | Server song catalog | **Dropped** |
| Q10 | Region limiting | **Dropped** |
| Q11 | Distribution and payments | **GitHub Releases only.** No Google Play, no other stores. Donations only through the external link `https://ko-fi.com/brinsley`, never in-app |
| Q12 | Translation provider | **MyMemory only**, called from the device. Azure is dropped |
| Q13 | Accounts | **None.** No sign-in (Google or otherwise), no account server, no sync. Everything runs on-device; libraries move between devices with backup and restore (FEATURES.md §7) |
| Q14 | Licence | **GPL-3.0** (the `LICENSE` in `kalaoapp/Kalao`); `[workspace.package] license = "GPL-3.0-only"`. Dependencies and stem models must be GPL-3.0-compatible |

## Open questions

None at the moment.

## Architecture decision records

**ADR-001 Flutter + Rust, Mornye `rust_backend/` template.** *Accepted (Q8).*

**ADR-002 No Kalao account server.** All app data is local, owned by `kalao-mobile`. The only Kalao-run service is the stem server, which knows API keys and device hashes, never people. *Accepted (Q13).*

**ADR-003 (revised) Bindings follow Mornye:** UniFFI Kotlin bindings from `kalao-mobile`, reached from Flutter through a MethodChannel/EventChannel; a C ABI `kalao-desktop` crate reached through `dart:ffi`; one JSON method table shared by both. This replaces the earlier flutter_rust_bridge plan. *Accepted (Q8).*

**ADR-004 (revised at M1) Audio engine in Rust, one deck.** All playback goes through `kalao-audio` (cpal/AAudio); `KaraokeDeck` is the only deck and `PlayerController` drives it directly, with the published `audio_service` package for the media session. Mornye's multi-deck `music_player_service.dart`, its `PlaybackDeck` interfaces, its `audio_service` fork and its `audioplayers` deck are not used: separate players drift between stems and have no key shift or mic path. *Accepted.*

**ADR-005 Time-stretch: Signalsmith Stretch (MIT) preferred over Rubber Band.** Both are GPL-3.0-compatible; Signalsmith is lighter and keeps licensing simple. *Confirmed at M3.1 (`signalsmith-stretch` 0.1.3).*

**ADR-006 (revised) Mornye's data split.** Dart owns the database schemas (sqflite: library, history, app state) and all SQL; Rust native data jobs do file and CPU work (hashing, search keys, backup archives) and never open the live databases; settings in `shared_preferences`, secrets in `flutter_secure_storage`. *Accepted.*

**ADR-007 No DRM.** There is no first-party hosted content to protect. *Accepted.*

**ADR-008 Content access happens on the device through extensions.** Kalao ships no scrapers. Extensions run in a QuickJS sandbox (`rquickjs`, as in Mornye) with declared host allowlists. Each extension's author is responsible for its terms of use. *Accepted (Q3).*

**ADR-009 Stem separation via ONNX Runtime on-device; Demucs on the GPU server.** One output format (FLAC stems keyed by the source SHA-256), whichever path produced them. Remote always falls back to local. *Accepted (Q4).*

**ADR-010 (revised) Translation: MyMemory from the device.** Client in `kalao-providers`; Mornye's `lyrics_translation.dart` handles distinct-line batching, caching and alignment. *Accepted (Q12, Q13).*

**ADR-011 Backup and restore instead of sync.** A versioned `.kalaobackup` zip (SQLite snapshot + manifest, optional media), merge or replace on restore, never containing secrets. *Accepted (Q13).*

**ADR-012 GitHub Releases is the only distribution channel.** Signed APKs (per-ABI and universal) with published SHA-256 checksums; an optional in-app update check that downloads the APK only when the user taps Update, verifies its SHA-256 and hands it to the system installer (always offering the release page). *Accepted (Q11).*

**ADR-013 Reuse Mornye code under its licence.** Copy or adapt Mornye files wherever they solve a Kalao need (MORNYE_REUSE.md), keep zarzet's copyright and an "adapted for Kalao" header, list Mornye in `NOTICE` and the Licences page, and ship Kalao as GPL-3.0-only (LGPL-3.0 code may be used in a GPL-3.0 work). Mornye's pinned dependency versions are kept. *Accepted.*

**ADR-014 Stems stored as FLAC.** Lossless, decoded by Symphonia, encoded by pure-Rust `flacenc`; avoids adding libopus. Costs about 2× the disk of Opus. *Accepted.*

**ADR-015 No Google Cast.** Mornye's cast support needs Play services. The TV lyrics view is a LAN web page served by the party host. *Accepted.*

**ADR-016 Scheduled backups run when the app opens.** No background scheduler (WorkManager) is added; a due backup runs on the next start or resume. *Accepted.*

**ADR-017 Public sample extension is LRCLIB.** The earlier "local LRC folder" sample needs filesystem access, which the sandbox forbids. LRCLIB is an open API and Mornye's `lrclib.rs` is a reference. *Accepted.*
