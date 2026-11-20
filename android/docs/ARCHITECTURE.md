# Architecture

Kalao follows Mornye's internal architecture: the same layers, the same transport between Dart and Rust, the same split of data ownership, and the same folder and file conventions. Mornye's large multi-deck files are not copied; Kalao implements smaller versions with the same roles (MORNYE_REUSE.md). Libraries and versions are in [LIBRARIES.md](LIBRARIES.md); how each subsystem works in [IMPLEMENTATION.md](IMPLEMENTATION.md); what each milestone built in [ROADMAP.md](ROADMAP.md).

Sections mark planned parts with *(planned, Mx)*; everything else exists.

## 1. System overview

```
┌───────────────────────────────── Android device ─────────────────────────────────┐
│ Flutter (Dart)                                                                   │
│  screens/ widgets/ providers/ (Riverpod 3) controllers/ services/ models/ theme/ │
│  services/platform_bridge.dart ── PlatformBridge: the only caller of the backend │
│  services/backend/backend_channel.dart ── BackendChannel (MethodChannel)         │
│        │ MethodChannel "com.brinsley.kalao/backend" + player_position_stream      │
│ Kotlin host (android/app/src/main/kotlin/com/brinsley/kalao/)                     │
│  MainActivity: nativeBackendMethods (SAF, services, OS) │ everything else ──►     │
│  src/rust/kotlin/SelectedCoreBackend.kt → UniFFI bindings (JNA) on Dispatchers.IO │
│  BackgroundWorkService (ref-counted foreground service; used by backups)          │
│        │ JNA                                                                      │
│ Rust: rust_backend/ → libkalao_mobile.so                                          │
│  kalao-mobile (UniFFI API, native data jobs) → kalao-audio · kalao-core           │
│  later: stems · extensions · providers (MyMemory) · party · network              │
└──────────┬────────────────────────┬──────────────────────────┬────────────────────┘
           │ extension fetch (M5)   │ MyMemory (M6)            │ optional donor API key (M6)
           ▼ (allowlisted hosts)    ▼ api.mymemory.translated  ▼
       third-party sites                                  Kalao stem server (stem-server/)
```

There is no account server. The only network call today is the optional GitHub Releases update check; the only Kalao-run service will be the optional stem server.

## 2. Repository layout

```
karaoke/                         # git root of kalaoapp/Kalao
├── rust_backend/                # shared Cargo workspace (§4)
├── scripts/                     # build_rust_backend.sh, check_rust_backend.sh, build_android.sh, check_backend_apk.py, rust_env.sh
├── android/                     # the Flutter app for Android
│   ├── lib/  test/  integration_test/  assets/
│   ├── android/                 # Gradle host
│   ├── pubspec.yaml  analysis_options.yaml  l10n.yaml  .fvmrc
│   ├── docs/                    # these documents
│   └── extensions/              # git-ignored private extensions (M5)
├── desktop/  web/               # later (M8.7)
├── stem-server/                 # Rust gateway + Python worker (M6.6)
├── .github/workflows/           # ci.yml, release.yml
├── LICENSE (GPL-3.0)  NOTICE (Kalao + Mornye attribution)  README.md
```

Kalao keeps one Flutter project per platform folder (Q6): `desktop/` will be a second Flutter project that reuses `android/lib/` through a shared Dart package extracted when desktop starts (`packages/kalao_app/`). Until then all Dart code lives in `android/lib/`.

## 3. Flutter app (`android/lib/`)

| Folder | Contents |
| --- | --- |
| `main.dart`, `app.dart` | Startup (error handlers, databases, media session, `ProviderContainer` overrides), `MaterialApp.router` with go_router; `initialLocationForAppState` sends a first start through `/setup` → `/tutorial` → `/whats-new` → `/` |
| `constants/` | `app_info.dart` (version, repository, donation URL) |
| `models/` | Hand-written `@immutable` classes with `fromJson`/`toJson`/`copyWith`: `settings.dart`, `song.dart`, `lyrics.dart`, `player_state.dart` (no code generation) |
| `services/` | All non-UI logic, one file per concern: `platform_bridge.dart`, `backend/`, `library_schema.dart`, `library_database.dart`, `history_database.dart`, `app_state_database.dart`, `library_queue_store.dart`, `library_search.dart`, `import_service.dart`, `lyrics_service.dart`, `karaoke_deck.dart`, `playback_handler.dart`, `backup_service.dart`, `backup_runs.dart`, `poc_import_service.dart`, `update_service.dart`, `app_crash_service.dart`, `app_storage.dart`, `custom_font_service.dart`, `external_links.dart` |
| `providers/` | Riverpod `Notifier`s and providers, thin over services: `settings_provider`, `library_provider`, `player_provider`, `queue_provider`, `backup_provider`, `update_provider` |
| `controllers/` | Multi-step flows without widgets: `lyrics_sync_editor_controller.dart` |
| `screens/` | `main_shell` (Home, Library, Queue, Extensions placeholder, Settings), `home_tab`, `library_screen`, `queue_tab`, `now_playing_screen` (Learn / Karaoke layouts), `lyrics_sync_screen`, import and lyrics sheets, `setup_screen`, `tutorial_screen`, `whats_new_screen`, `stats_screen`, `shared_files`, `settings/*` |
| `widgets/` | `ruby_lyric_line` (ruby layout + `SweepText`), `lyric_line_view`, `screen_awake`, `karaoke_lyrics_view`, `mini_player`, `song_widgets`, `stepper_tile`, `update_dialog`, `settings_group`, `empty_state`, `app_crash_banner` |
| `theme/` | `app_tokens`, `app_theme` (Material 3, brand palette, Material You through `dynamic_color`) |
| `l10n/` | `arb/app_{en,zh,zh_Hant,ja}.arb`, generated `app_localizations*.dart` (git-ignored), `supported_locales.dart` |
| `utils/` | `logger.dart` (`AppLogger`, `LogBuffer`), `lyrics_timeline.dart` (sweep and line timing maths) |

Rules: no business logic in widgets or providers; services own I/O; every backend call goes through `PlatformBridge`; long JSON is decoded off the UI isolate.

## 4. Rust workspace (`rust_backend/`)

Workspace settings: `resolver = "3"`, edition 2024, `rust-version = "1.99.0"`, toolchain `1.99.1` (`profile = "minimal"`, rustfmt + clippy), `[workspace.dependencies]` with exact pins, `[workspace.lints]` with `unsafe_code = "deny"`, release profile with thin LTO. Licence `GPL-3.0-only`.

| Crate | Package | Origin | Owns | Depends on |
| --- | --- | --- | --- | --- |
| `crates/core` | `kalao-core` | Mornye `core` (subset) + new | JSON helpers, text, XML depth check, lyrics (`lrc`, `payloads/ttml`, and Kalao's `doc`: LRC/eLRC/TTML/plain import and LRC/eLRC export), `sections`, `annotate` (pinyin, furigana and romaji, Chinese variants), `search_keys`, `pairing` | none |
| `crates/audio` | `kalao-audio` | new | Karaoke engine: synchronised decoders, mixer, crossfade, key/tempo (Signalsmith Stretch), loops, clock, cpal/AAudio output, `probe_file`; later mic input, pitch tracking, reverb, recording (M7, M8) | none |
| `crates/mobile` | `kalao-mobile` | Mornye `mobile` (skeleton) | UniFFI API, `invoke_application` dispatch, cancellation registry, log buffer, native data jobs (`hash_file`, `importInspect`, `importStore`, `rebuildSearchKeys`, `backupWrite`, `backupInspect`), backup archive codec, player/lyrics/import methods, the player state publisher | core, audio |
| `crates/bindgen` | `kalao-bindgen` | Mornye `bindgen`, unchanged | UniFFI CLI for the Kotlin bindings | uniffi only |
| `crates/network` *(planned, M5)* | `kalao-network` | Mornye `network`, unchanged | Cancellable HTTP client, cookies, DNS, TLS roots, request policy | none |
| `crates/extensions` *(planned, M5)* | `kalao-extensions` | Mornye `extensions` (subset) | QuickJS runtime, host APIs, manifest, package, repository, storage, lyrics/metadata/health backends | core, network, providers |
| `crates/providers` *(planned, M6)* | `kalao-providers` | Mornye `providers` (structure) | MyMemory translation client, request coalescer | core, network |
| `crates/stems` *(planned, M6)* | `kalao-stems` | new | ONNX separation, model manager, resumable chunked jobs, FLAC output, remote stem-server client | core, network |
| `crates/party` *(planned, M8)* | `kalao-party` | Mornye `link` | LAN party host: HTTPS + WebSocket, PIN pairing, room state, TV lyrics page | core |
| `crates/desktop` *(planned, M8.7)* | `kalao-desktop` | Mornye `desktop` | C ABI over the same method table | mobile |
| `crates/ext-cli` *(planned, M5)* | `kalao-ext` | new | Extension author CLI (validate, test, pack, sign) | extensions |

`crates/mobile/uniffi.toml`: `package_name = "com.brinsley.kalao.backend"`, `cdylib_name = "kalao_mobile"`. Dependencies point downward; `core`, `audio` (and later `network`) depend on no workspace crate.

## 5. Dart ↔ Kotlin ↔ Rust transport

- **One backend channel:** `MethodChannel("com.brinsley.kalao/backend")`. Dart side: `PlatformBridge` → `backendChannel` (`MethodChannelBackend`; a `RustFfiBackend` over `dart:ffi` arrives with desktop).
- **Arguments:** `PlatformBridge` sends the arguments of Rust methods as JSON text, which Kotlin passes to Rust unchanged; Android-native methods take a map.
- **Android routing:** `MainActivity` keeps a `nativeBackendMethods` set for calls Kotlin must handle (SAF, foreground service, installer, screen-awake, ABIs, crash report, shared files). Every other name goes to `dispatchBackendApplication` in `src/rust/kotlin/SelectedCoreBackend.kt`, which converts the arguments to JSON and runs `invokeApplication(method, argsJson)` on `Dispatchers.IO`. `MainActivityRoutingTest` fails if the set and the `when` labels differ. Handlers live in `MainActivity*Calls.kt` extension files (`MainActivityCalls.kt`, `MainActivityStorageCalls.kt`, `MainActivityUpdateCalls.kt`).
- **Replies:** JSON text, decoded by Dart (in an isolate above 64 KiB). Replies over 256 KiB use the **`__json_file` spill** (`{"__json_file": path}` in `cacheDir`, read and deleted by Dart; stale files swept at engine setup).
- **Errors:** `result.error(code, message)`; `foreground_service_start_not_allowed` when Android refuses a service start, otherwise `ERROR`.
- **Position stream:** on `com.brinsley.kalao/player_position_stream` (`MainActivityProgressStreams.kt`), Kotlin subscribes a UniFFI callback (`player_subscribe`); a Rust thread (`kalao-state`) sends the engine state when it changes — every 33 ms while playing and at once after a command — and Kotlin forwards `{state, atMicros}`, `atMicros` being the CLOCK_MONOTONIC instant of the state. `KaraokeDeck` interpolates from that instant (Dart's `Timeline.now` reads the same clock), so channel delays do not move the lyrics. Further streams (`pitch_stream`, `stem_progress_stream`, `party_event_stream`) and host → Dart events (`extensionAuthCallbackReceived`, `stemJobChanged`, `partyGuestEvent`, `audioRouteChanged`) arrive with their features.
- **Native data jobs:** `runNativeDataJob(request_json, request_id)` / `cancelNativeDataJob(request_id)` for heavy file and CPU work, with a cancellation registry (`NativeDataJobs.kt`); a lease is taken before the job is queued, so a cancel also reaches work that has not started.
- **Bindings:** UniFFI Kotlin bindings are generated into `rust_backend/target/bindings/kotlin/` and loaded through JNA (`net.java.dev.jna:jna:5.19.1@aar`; ProGuard keeps `com.sun.jna`). Gradle's `buildRustBackend` task runs `scripts/build_rust_backend.sh android` before `preBuild`.

## 6. Data ownership

| Data | Owner | Storage |
| --- | --- | --- |
| Library schema (songs, media files, lyrics, annotations, search keys, favorites, backup log) | **Dart** `services/library_schema.dart` + `library_database.dart` (sqflite) | `kalao_library.db` |
| Play history | Dart `history_database.dart` | `kalao_history.db` |
| Queue, playback session, recent access | Dart `app_state_database.dart`, `library_queue_store.dart` | `kalao_app_state.db` |
| Settings | Dart `models/settings.dart` via `settings_provider` | `shared_preferences` |
| Imported audio and covers | Dart `import_service.dart` | `media/<sha256>.<ext>`, `covers/` in app support |
| Backup archives | Rust `kalao-mobile::native_backup` (codec), Dart `backup_service.dart` (contents, restore) | `.kalaobackup` files |
| Secrets *(M5–M6)* (stem key, install ID, extension secrets) | Dart, `flutter_secure_storage` (Keystore) | — |
| Extension packages, storage and cookies *(M5)* | Rust `kalao-extensions` | App-private files |
| Stem models, checkpoints, stem files *(M6)* | Rust `kalao-stems` | App-private files, keyed by audio SHA-256 |

The schema stays owned by Dart; Rust never opens the live databases.

## 7. Playback architecture

- One deck: `KaraokeDeck` (`services/karaoke_deck.dart`) sends engine commands through `PlatformBridge` and interpolates the position between `player_position_stream` events. `PlayerController` (`providers/player_provider.dart`) owns player state, modes, loops, history rows, session restore and the queue advance (the roles of Mornye's `music_player_service.dart` + `playback_session_restore.dart`). `KalaoAudioHandler` (`services/playback_handler.dart`) is the `audio_service` media session; `AudioFocus` handles focus with `audio_session`.
- Two independent players cannot keep stems sample-aligned and have no pitch shift or mic path, so all audio goes through `kalao-audio`.
- The engine clock is the single source of truth for lyric sync.

## 8. Lyrics pipeline

1. **Source:** imported or shared file, pasted text, embedded tags, or the sync editor (later: extension results).
2. **Parse:** Rust `parseLyrics` (`core::lyrics::doc`: LRC, enhanced LRC, TTML, plain text; sections detected by `core::sections`) → lyric document JSON → Dart `LyricDocument` (`models/lyrics.dart`).
3. **Annotate:** `annotateLyrics(lines)` → the language Rust detects (`ja` when a line has kana, `zh` when one has Han characters) and its ruby layers (`furigana` + `romaji`, or `pinyin`) aligned to UTF-16 ranges. `parseLyrics` already gives each word its UTF-16 offset in the line.
4. **Store:** `lyric_doc` + `lyric_annotation` rows (`LyricsService`, `LibraryDatabase`); the last five versions are kept; `origin = human` layers are never overwritten.
5. **Display:** `convertChinese` applies the Traditional/Simplified setting at load (never stored); `lyric_line_view.dart` and `ruby_lyric_line.dart` lay out the layers and the sweep; `utils/lyrics_timeline.dart` holds the timing maths.
6. **Translate** *(M6)*: MyMemory, distinct lines once, cached.

## 9. Android host (`android/android/app/src/main/kotlin/com/brinsley/kalao/`)

`KalaoApplication.kt` (crash capture), `MainActivity.kt` (routing), `MainActivityCalls.kt` (screen awake, background work, crash report), `MainActivityStorageCalls.kt` (SAF: save a document, backup folder), `MainActivityUpdateCalls.kt` (ABIs, APK installer through a `FileProvider`), `MainActivityProgressStreams.kt`, `SharedFiles.kt` (VIEW/SEND intents), `BackgroundWorkService.kt` + `ForegroundServiceStartPolicy.kt` + `ForegroundWorkLock.kt` + `CoalescingWorkRefresh.kt`, `AppCrashReporter.kt`, `NativeCrashTrace.kt`; `src/rust/kotlin/{SelectedCoreBackend,NativeDataJobs}.kt`; `src/test/kotlin/MainActivityRoutingTest.kt`. Later: player calls (audio permissions, routes, M7), party calls (multicast lock, M8), extension auth callbacks (M5).

Manifest: `minSdk 26`, `targetSdk 37`, `compileSdk 37`, NDK `30.0.16248370`, 16 KB page-aligned `.so`, ABI splits (arm64-v8a, armeabi-v7a, x86_64) plus universal. Permissions are added with the features that need them: today `INTERNET`, `FOREGROUND_SERVICE` (+ media playback and data sync types), `POST_NOTIFICATIONS`, `WAKE_LOCK`, `REQUEST_INSTALL_PACKAGES`; later `RECORD_AUDIO` (M7), `CHANGE_WIFI_MULTICAST_STATE` and `CAMERA` (M8). No Google Play services.

## 10. Stem server (`stem-server/`, M6.6)

Separate deployment with its own Cargo workspace: Rust (axum) gateway with key whitelist, device binding, rate limits and job API; Python worker running Demucs on a GPU via a Redis queue; `stem-admin` CLI; Prometheus `/metrics` behind an admin token. See STEM_SEPARATION.md and API.md.

## 11. Ownership table

| Concern | Single owner |
| --- | --- |
| Backend transport | `services/backend/` + `platform_bridge.dart` (Dart), `SelectedCoreBackend.kt` (Android), `kalao-mobile` (Rust) |
| Audio clock and output | `kalao-audio` |
| Player state, queue advance, media session | `PlayerController` via `KaraokeDeck`; `KalaoAudioHandler` |
| Active lyric line and sweep | `LyricDocument.activeLineAt` and `utils/lyrics_timeline.dart` |
| Lyric parsing and export | `kalao-core::lyrics::doc` |
| Annotation generation | `kalao-core::annotate` |
| Library and history schemas | Dart services (`library_schema.dart`) |
| Backup layout and restore | Dart `backup_service.dart`; archive codec in `kalao-mobile::native_backup` |
| Updates | `update_service.dart` + `update_provider.dart` |
| Stem separation *(M6)* | `kalao-stems` |
| Third-party content access *(M5)* | extensions, via `kalao-extensions` host fetch only |
| Translation *(M6)* | `kalao-providers` (MyMemory client) + a Dart translation service (dedupe, cache, alignment) |
| Stem API key validity and device binding *(M6)* | stem server gateway |
