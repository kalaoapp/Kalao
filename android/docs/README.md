# Kalao: Design Documentation

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/M5S22AP7IF)

**Kalao** (pronounced *ka-la-oh*), application ID `com.brinsley.kalao`, is the ground-up rebuild of the `poc-webapp` karaoke POC as a native app. It is built with **Flutter** (UI) and **Rust** (engine, lyrics, heavy data jobs), using the same template as Mornye's `rust_backend/`: one Cargo workspace of focused crates and a UniFFI mobile crate for Android (a C ABI desktop crate follows with `desktop/`).

This folder (`android/`) is the Android app. Desktop and web will live in their own top-level folders (`desktop/`, `web/`), separate from `poc-webapp/`. The shared Rust workspace lives at the top level in `rust_backend/`.

These documents also describe planned work (extensions, stems, scoring, parties). ROADMAP.md says what each milestone has built; ARCHITECTURE.md and DATA_MODEL.md mark planned parts with their milestone.

| Doc | Contents |
| --- | --- |
| [FEATURES.md](FEATURES.md) | Full feature spec: every POC feature and roadmap item, mapped to Kalao |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Layers, folders, Rust crates, Dart ↔ Kotlin ↔ Rust transport, data ownership, playback, lyrics pipeline (Mornye's internal architecture) |
| [MORNYE_REUSE.md](MORNYE_REUSE.md) | What is copied, adapted or not used from Mornye, file by file, and the licence/attribution rules |
| [LIBRARIES.md](LIBRARIES.md) | Toolchains and every Dart, Kotlin and Rust dependency with versions |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | How each subsystem is built: method table, audio engine, lyrics and annotation, modes, scoring, extensions, translation, backup, parties, updates, testing |
| [EXTENSIONS.md](EXTENSIONS.md) | **Public** guide: how the extension framework works and how to write an extension |
| [STEM_SEPARATION.md](STEM_SEPARATION.md) | On-device stem separation and the optional remote stem server |
| [DATA_MODEL.md](DATA_MODEL.md) | Local SQLite schema, timed-lyrics format, backup format, stem-server tables |
| [API.md](API.md) | Stem server API and the external services the app calls |
| [SECURITY.md](SECURITY.md) | Threat model, secrets, extension sandbox |
| [DECISIONS.md](DECISIONS.md) | Owner decisions, ADRs, remaining open questions |
| [ROADMAP.md](ROADMAP.md) | Milestones M0–M8 as task lists covering every feature, plus a coverage table |
| [DEV_SETUP.md](DEV_SETUP.md) | Toolchain, build and test commands |
| [BRANDING.md](BRANDING.md) | Brand colours, the app's Material colour scheme, icons and typography (from [kalaoapp/branding](https://github.com/kalaoapp/branding)) |

## Guiding principles

1. **Free, no paywall.** Every feature is available to everyone. There are no tiers and no in-app checks for donations. A single non-intrusive *Support Kalao* link opens [ko-fi.com/brinsley](https://ko-fi.com/brinsley) in the browser. There are no popups, nags, prompts or in-app payments.
2. **No accounts.** There is no sign-in of any kind and no Kalao account server. Everything runs on the device; the library is moved between devices with backup and restore.
3. **Mornye's architecture.** Rust runs the engine work (audio, pitch, annotation, stems, extensions, archive codecs, heavy data jobs); Dart owns UI, state, the database schemas and app logic; Kotlin is a thin host. Mornye code is reused wherever it already exists (MORNYE_REUSE.md).
4. **Content comes from extensions.** Kalao ships no scrapers. Lyrics, metadata and audio sources are provided by sandboxed, user-installed extensions. The framework and its docs are public; individual extensions are distributed separately.
5. **No secrets in the app.** The app ships no service keys. It holds only what the user enters (an optional stem-server key, extension secrets, an optional MyMemory contact email), in Keystore-backed secure storage.
6. **Offline-first.** Playback, annotation and stem separation work without a network. The network is used only by extensions, translation, the optional remote stem server and the optional update check.
7. **Timed lyrics are first-class.** Line and word timing drive auto-sync, OG Karaoke mode, scoring and parties.
8. **One feature, one owner.** See the ownership table in ARCHITECTURE.md.
9. **Distributed only through GitHub Releases.**
