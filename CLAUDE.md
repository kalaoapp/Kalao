# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Kalao** (`com.brinsley.kalao`) is an on-device karaoke and lyrics-learning app: Flutter UI, Rust engine, thin Kotlin host. Android first; `desktop/` and `web/` come later. GPL-3.0-only. It reuses the architecture and code of [Mornye](https://github.com/mornyeapp/Mornye) (LGPL-3.0-only).

The design docs in `android/docs/` are the source of truth and are written ahead of the code — they describe planned folders, crates and services that do not exist yet. Check `android/docs/ROADMAP.md` for what each milestone (M0–M8) has actually built before assuming something exists. Start at `android/docs/README.md`; `ARCHITECTURE.md` and `IMPLEMENTATION.md` cover the design, `DECISIONS.md` the owner decisions.

Hard product constraints (do not design around them): no accounts or sign-in, no paywall or in-app donation checks, no service keys shipped in the app, no bundled scrapers (content comes from user-installed extensions), offline-first, distributed only through GitHub Releases.

## Tech stack

| Layer | Versions |
| --- | --- |
| Flutter | 3.47.8, pinned in `android/.fvmrc` (use `fvm flutter …` locally; CI uses plain `flutter`). Dart SDK `^3.10.0` |
| Dart packages | `flutter_riverpod` ^3.4.2, `go_router` ^18.1.2, `sqflite` ^2.4.5, `shared_preferences` ^2.5.6, `flutter_secure_storage` 10.3.4 (pinned), `audio_service` ^0.18.19, `audio_session` ^0.2.4, `ffmpeg_kit_flutter_new_audio` 2.5.7, `file_picker` ^13.3.0, `dynamic_color` ^2.1.0, `material_ui` ^1.9.0, `intl` ^0.20.3, `path_provider` ^2.1.6, `url_launcher` 6.3.3, `share_plus` 13.3.1, `http` 1.6.0 (the last three pinned). Dev: `flutter_lints` ^6.0.0, `riverpod_lint` ^3.1.9, `sqflite_common_ffi` ^2.4.5 |
| Rust | Toolchain 1.99.1 (`rust_backend/rust-toolchain.toml`), edition 2024, resolver 3, `rust-version` 1.99.0. `uniffi` =0.32.2, `tokio` =1.54.1, `symphonia` 0.5.5, `cpal` 0.16, `rubato` 0.16, `signalsmith-stretch` =0.1.3, `lindera` =6.2.0 (IPADIC embedded), `ferrous-opencc` =0.4.0, `serde`/`serde_json` 1.0, `thiserror` 2.0, `pinyin_pro` =3.29.4 |
| Android | AGP 9.5.0, Kotlin 2.4.21, Gradle 9.8.2, JDK 25 (Temurin), `compileSdk`/`targetSdk` 37, `minSdk` 26, NDK 30.0.16248370, `kotlinx-coroutines-android` 1.11.0, JNA for the UniFFI bindings |
| Tooling | Git Bash for `scripts/*.sh`, Python 3 for `scripts/check_backend_apk.py`, `git-cliff` (changelog), Renovate, gitleaks |

Versions follow Mornye's pins; `android/docs/LIBRARIES.md` lists every dependency. Dart packages are added in the milestone that first uses them.

## Repository layout

```
rust_backend/            Cargo workspace (the engine)
  crates/core            kalao-core: JSON/text helpers, lyrics (LRC, eLRC, TTML, doc), sections, annotate (pinyin, furigana/romaji, Chinese variants), pairing, search keys
  crates/audio           kalao-audio: playback engine (Symphonia → rubato → ring buffers → mixer → cpal/AAudio)
  crates/mobile          kalao-mobile: UniFFI API, method table, native data jobs, log buffer (builds libkalao_mobile.so)
  crates/bindgen         kalao-bindgen: UniFFI CLI that generates the Kotlin bindings
android/                 Flutter project (package name `kalao`)
  lib/                   main.dart, app.dart, constants/ controllers/ models/ providers/ screens/ services/ theme/ utils/ widgets/ l10n/
  integration_test/      on-device tests against the real engine
  test/                  Dart tests; test/support/ holds fakes
  android/               Gradle host; Kotlin in app/src/main/kotlin/com/brinsley/kalao/ and app/src/rust/kotlin/
  docs/                  design docs
scripts/                 build_rust_backend.sh, check_rust_backend.sh, build_android.sh, check_backend_apk.py (+ test)
.github/workflows/       ci.yml, release.yml
poc-webapp/              old Next.js POC — git-ignored, never commit or publish (leaked secrets, copyrighted audio)
```

Crate dependencies point downward: `core` and `audio` depend on no other workspace crate; `mobile` depends on `core` and `audio`. Mornye's `network` crate is copied back when extensions need it (M5).

## Architecture

**Layering.** Rust does engine work (audio, lyrics parsing, annotation, heavy data jobs). Dart owns UI, state, app logic and the **database schemas** (sqflite; `services/library_schema.dart`). Kotlin is a thin host.

**One backend channel.** Every Dart → native call goes through `PlatformBridge` (`android/lib/services/platform_bridge.dart`), a class of typed static wrappers over `backendChannel` (`services/backend/`), on `MethodChannel("com.brinsley.kalao/backend")`.

- `MainActivity.kt` holds a `nativeBackendMethods` set for calls Kotlin answers itself (Android APIs, foreground service, crash report). Every other method name is forwarded by `dispatchBackendApplication` (`src/rust/kotlin/SelectedCoreBackend.kt`) to Rust on `Dispatchers.IO`.
- Rust entry point: `invoke_application(method, args_json)` in `rust_backend/crates/mobile/src/backend.rs`. Arguments are a JSON object, replies are JSON text.
- Replies over 256 KiB are written to a cache file and returned as `{"__json_file": path}`; `PlatformBridge` reads and deletes it. Large JSON is decoded off the UI isolate.
- Heavy file and CPU work (hashing, import, search keys, backup archives) goes through `runNativeDataJob` / `cancelNativeDataJob` with a cancellation registry.
- Rust method arguments are sent by `PlatformBridge` as JSON text; Kotlin passes them through. The engine state reaches Dart on `player_position_stream`, pushed by Rust (`player_subscribe`) with a CLOCK_MONOTONIC timestamp.

**Adding a backend method** touches each layer, and tests enforce the contract:

1. Rust: add the name to the sorted `METHODS` table in `backend.rs` and to `dispatch` (a test checks every listed name is dispatched). Implementation goes in the owning crate, not in `mobile`.
2. Kotlin, only if it needs Android APIs: add the name to `nativeBackendMethods` **and** the `when` in the same change (`MainActivityRoutingTest` fails if they differ). Handlers live in `MainActivity*Calls.kt` extension files.
3. Dart: add a typed static wrapper on `PlatformBridge`, and a stand-in to `test/support/fake_backend.dart`.

**Lyrics.** `LyricsService` (`services/lyrics_service.dart`) imports, saves and exports lyric documents; `utils/lyrics_timeline.dart` holds the timing maths; the sync editor's logic is `controllers/lyrics_sync_editor_controller.dart`.

**Queue.** `QueueStore` (`services/library_queue_store.dart`) persists the singing queue; `queueProvider`/`QueueActions` expose it; `PlayerController.playNextInQueue` advances it when a song ends.

**Playback.** `KaraokeDeck` (`services/karaoke_deck.dart`) drives `kalao-audio` through `PlatformBridge`; `PlayerController` (`providers/player_provider.dart`) owns player state; `KalaoAudioHandler` (`services/playback_handler.dart`) is the `audio_service` media session. The engine clock is the single source of truth for lyric sync.

## Commands

Run from the repository root unless noted.

```sh
# Rust
bash scripts/check_rust_backend.sh               # cargo fmt --check, clippy -D warnings, cargo test (workspace, --locked)
bash scripts/build_rust_backend.sh host          # host library + Kotlin bindings in rust_backend/target/bindings/kotlin/
bash scripts/build_rust_backend.sh android       # + libkalao_mobile.so per ABI in rust_backend/target/android/jniLibs/
cd rust_backend && cargo test -p kalao-core lrc  # one crate / tests matching a name

# Flutter (in android/)
fvm flutter pub get
fvm dart format lib test
fvm flutter analyze
fvm flutter test
fvm flutter test test/player_test.dart --plain-name "test name"   # one file / one test
fvm flutter run                                  # Gradle's buildRustBackend runs the android Rust build before preBuild

# Kotlin and scripts
gradle -p android/android :app:assembleDebug :app:testDebugUnitTest
python3 -m unittest discover -s scripts -p 'test_*.py'

# Release APKs (per ABI + universal, obfuscated, audited by check_backend_apk.py)
bash scripts/build_android.sh
```

- `KALAO_RUST_ANDROID_ABIS` selects ABIs (default `arm64-v8a,armeabi-v7a,x86_64`); do not pass `--target-platform` / `--split-per-abi` to `build_android.sh`. `ANDROID_NDK_HOME` must point to NDK 30.0.16248370.
- Localizations (`lib/l10n/app_localizations*.dart`) are generated from `lib/l10n/arb/` and git-ignored; `flutter pub get` regenerates them.
- Windows: Gradle's `buildRustBackend` finds Git Bash by full path (Windows would otherwise start WSL's `System32\bash.exe`), via a `bash.exe` on PATH or Git's `cmd\git.exe`. Without Git Bash, run `bash scripts/build_rust_backend.sh android` first and pass `-x buildRustBackend` to Gradle. Without Developer Mode, link the FVM SDK with a junction (see `android/docs/DEV_SETUP.md`).
- Linux hosts need `libasound2-dev pkg-config` for the `cpal` host build and `libclang-dev` for `signalsmith-stretch` (bindgen). On Windows `scripts/rust_env.sh` points bindgen at the NDK's libclang; `source` it before running cargo by hand.

**Before a pull request:** `bash scripts/check_rust_backend.sh`, then `fvm flutter analyze && fvm flutter test` in `android/`.

**CI** (`ci.yml`, on pull requests and pushes to `main`): gitleaks plus a check that no `*.kalaoext`, `android/extensions/` or `poc-webapp/` file is tracked; `dart format` (must produce no diff), analyze, test; Rust checks and script tests; Android `assembleDebug` + `testDebugUnitTest`, release APK build, payload audit, `apksigner`/`zipalign -P 16` checks.

**Release** (`release.yml`): push a tag `vX.Y.Z` that matches `version:` in `android/pubspec.yaml`. CI builds arm64/arm32/x86_64/universal APKs, signs them V1–V4 from repository secrets, audits them, and publishes a GitHub Release with `SHA256SUMS.txt` and a `git-cliff` changelog. There is no other deploy target.

## Testing approach

- **Rust:** unit tests in a `#[cfg(test)] mod tests` at the bottom of each file; larger suites in a sibling `tests.rs` (`audio/src/tests.rs`, `core/src/lyrics/payloads/tests.rs`). Fixtures in `crates/core/tests/fixtures/`. Audio tests assert on rendered buffers, not on device output.
- **Dart:** `flutter_test` unit and widget tests, one `<area>_test.dart` per area in `android/test/`. No test talks to a real backend: `FakeBackend` (`test/support/fake_backend.dart`) mocks the method channel, answering Rust methods with JSON text as the Android host does and recording `calls` for assertions; `test/support/test_services.dart` supplies the rest. Databases run on `sqflite_common_ffi`.
- **Kotlin:** `MainActivityRoutingTest` guards the native-method routing contract.
- **Python:** `scripts/test_check_backend_apk.py` (`unittest`).
- **On device:** `android/integration_test/` (`fvm flutter test integration_test` with a device attached) runs against the real engine; CI does not run it.

## Conventions

**Naming**

- Dart: `snake_case.dart` files with a role suffix — `*_provider.dart`, `*_screen.dart` / `*_tab.dart` / `*_sheet.dart`, `*_service.dart`, `*_database.dart` / `*_schema.dart`; design-system widgets are `app_*`. Providers are `fooProvider` backed by a `FooNotifier` / `FooController`. Imports are absolute (`package:kalao/...`).
- Backend method names are `camelCase` strings shared verbatim by Dart, Kotlin and Rust, grouped by prefix (`playerLoad`, `playerSeek`, …).
- Rust: packages `kalao-<crate>` in `crates/<crate>`; modules use `foo.rs` + `foo/` (no `mod.rs`).
- Kotlin: `MainActivity<Area>Calls.kt` extension files with `handle<MethodName>` functions.
- Formatting comes from `.editorconfig`: LF, UTF-8, 2 spaces for Dart/JSON/YAML, 4 for Rust/Kotlin/TOML.

**Dart**

- No business logic in widgets or providers; services own I/O; backend calls only through `PlatformBridge`.
- Analyzer runs with `strict-casts`, `strict-inference`, `strict-raw-types`, `avoid_dynamic_calls`, `type_annotate_public_apis` and `riverpod_lint`. `flutter analyze` must be clean.
- Models are `@immutable` plain classes with hand-written `fromJson` / `toJson` / `copyWith` / `==`. `fromJson` is tolerant: every field is cast as nullable with a default (`json['x'] as String? ?? ''`) and unknown keys are ignored. There is no `json_serializable` or `build_runner` yet. Nullable fields in `copyWith` take a closure (`localeTag: () => tag`).
- Riverpod 3 `Notifier` + `NotifierProvider`, no code generation. Notifiers funnel writes through one private `_save` that updates `state` and persists. Dependencies opened in `main` are injected with `overrideWithValue` (e.g. `sharedPreferencesProvider`).
- Logging: a file-level `const _log = AppLogger('Tag');`, never `print`.
- User-facing strings go in all four ARB files (`app_en`, `app_zh`, `app_zh_Hant`, `app_ja`).

**Rust**

- `unsafe_code = "deny"` workspace-wide; `thiserror` error enums; no `unwrap` outside tests; `--locked` on every cargo command.
- Dependencies are declared once in `[workspace.dependencies]` (many pinned with `=`) and referenced as `foo.workspace = true`; every crate inherits `[lints] workspace = true`.
- Process-wide state uses `OnceLock<Mutex<…>>` behind an accessor function.

**Repo-wide**

- Files derived from Mornye keep the attribution header (`// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.`); see `android/docs/MORNYE_REUSE.md`.
- Update `android/docs/` in the same change when behaviour, data formats or the roadmap change.
- Never commit secrets, signing keys (`key.properties`, `*.jks`), audio or other media, extension packages (`*.kalaoext`, `android/extensions/`), or anything from `poc-webapp/`.
- GitHub Actions are pinned by commit SHA with a version comment.
- Pushing changes under `.github/workflows/` needs the `workflow` scope on the `gh` token (`gh auth refresh -h github.com -s workflow`).
