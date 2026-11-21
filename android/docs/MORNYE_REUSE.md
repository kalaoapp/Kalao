# Reusing Mornye

Kalao is built on Mornye's code wherever Mornye already solves the problem. This file says, per area, what was **copied** (renamed only), **adapted** (copied, then changed for karaoke), **written Kalao-sized** instead, **planned** for a later milestone, or **not used**. Paths are relative to the Mornye repo root (`mornyeapp/Mornye`). Every file that came from Mornye carries the attribution header (`git grep -l "Derived from Mornye"` lists them).

## 1. Licence and attribution (do this with every copied file)

- Mornye is **LGPL-3.0-only** (`LICENSE`, `COPYING`, `NOTICE`: "Copyright 2026 zarzet"). LGPL-3.0 lets the code be used in a GPL-3.0 work, so Kalao ships as **GPL-3.0-only**.
- Keep Mornye's copyright line. Every copied file gets a header: `// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.` Rust files use `//!` or `//` the same way; Kotlin uses `//`.
- Kalao's `NOTICE` lists Mornye and every vendored third-party package (`third_party/*/LICENSE` and `MORNYE_PATCHES.md` files are kept as they are, with a `KALAO_PATCHES.md` added next to them if Kalao changes them further).
- `assets/licenses/` and the in-app Licences page include Mornye.
- Rename identifiers when copying: `mornye` → `kalao`, `Mornye` → `Kalao`, `com.zarz.mornye` → `com.brinsley.kalao`, `com.mornye.backend` → `com.brinsley.kalao.backend`, `mornye_mobile` → `kalao_mobile`, `MORNYE_*` env vars → `KALAO_*`. Do not keep Mornye's branding, icons, fonts or brand assets.
- Drop Mornye's Go-compatibility code paths ("retired Go backend" contracts, `legacy_host`, `native_backup/legacy.rs`) unless a copied module needs them to compile; Kalao has no legacy formats to read.

## 2. Repository and tooling

| Mornye | Kalao | Status |
| --- | --- | --- |
| `.editorconfig`, `.gitattributes`, `analysis_options.yaml`, `devtools_options.yaml`, `renovate.json`, `.fvmrc`, `l10n.yaml`, `cliff.toml` | root and `android/` | Copied |
| `.github/workflows/ci.yml` | root | Adapted: no iOS or Discord jobs; Flutter format/analyze/test, `check_rust_backend.sh`, Android assemble + `testDebugUnitTest` + APK payload audit; gitleaks and the no-extensions-tracked check added |
| `.github/workflows/release.yml` | root | Adapted: Android only; APK splits, V1–V4 signing and verification, payload audit, symbol retention, GitHub Release with SHA-256 checksums |
| `.github/ISSUE_TEMPLATE/*`, `PULL_REQUEST_TEMPLATE.md`, `FUNDING.yml` | root | Adapted (lyrics template added, `ko_fi: brinsley`) |
| `scripts/build_rust_backend.sh`, `check_rust_backend.sh`, `build_android.sh`, `check_backend_apk.py`, `test_check_backend_apk.py` | `scripts/` | Copied and renamed; `rust_env.sh` is Kalao's |
| `CONTRIBUTING.md` | root | Adapted |
| `.github/workflows/desktop.yml`, `actionlint.yaml`, `CODE_OF_CONDUCT.md`, `crowdin.yml`, `check_android_statx.sh`, `test_build_android.py` | — | Not copied (desktop later; the rest when needed) |
| `scripts/prepare_flutter_sdk.dart` and `patches/flutter/` | — | Not used: Kalao builds with stock Flutter |

## 3. Rust workspace

| Mornye | Kalao | Status |
| --- | --- | --- |
| `rust_backend/Cargo.toml`, `rust-toolchain.toml`, `README.md` | `rust_backend/` | Structure copied; members and dependencies are Kalao's (LIBRARIES.md) |
| `crates/network` | `crates/network` | **Copied** unchanged (M0; removed while nothing linked it, restored in M5) |
| `crates/bindgen` | `crates/bindgen` | **Copied** unchanged |
| `crates/core`: `json`, `text`, `xml`, `matching`, `lyrics/{lrc,json,payloads,payloads/ttml}` | `crates/core` | **Copied**. `lyrics/doc`, `sections`, `annotate`, `search_keys`, `pairing` are Kalao's. `cancellation`, `app_version`, `lyrics/{matching,errors}` were removed; M5 did not need them (cancellation lives in `kalao-mobile`, ranking in `kalao-extensions::capabilities`) |
| `crates/core`: `filename`, `tags`, `cover`, `progress`, `isrc` | — | Not copied: Symphonia's metadata reader covers read-only import; `progress` comes with model downloads (M6) |
| `crates/mobile`: `lib.rs` scaffolding, `data_jobs`, `logging` | `crates/mobile` | **Copied** and trimmed. `backend`, `player`, `lyrics`, `media`, `native_backup` and a small `cancellation` registry are Kalao's |
| `vendor/rustix-1.1.6` | — | Copied with the first crate that depends on `rustix` |
| `crates/extensions`: `runtime`, `host`, `manifest`, `package`, `repository`, `storage`, `manager/{install,lifecycle,info,providers,metadata}`, `network_host`, `crypto`, `crypto_host`, `redact`, `logging`, `provider.rs`, `provider.js`, `prelude.js`, `backend/{lyrics,metadata,health}`, `auth`, `environment`, `resolution` | `crates/extensions` | **Written Kalao-sized** (M5): Mornye's crate (33k lines) is built around downloads, FFmpeg, signed sessions, file hosts and Go compatibility. Kalao keeps its shape — one worker VM per extension, `RuntimeLimits`, an interrupt deadline, a host object over native calls, the redaction patterns (`logs.rs`) — with EXTENSIONS.md's API, manifest and capabilities |
| `crates/providers` | `crates/providers` | Planned (M6): keep the crate shape and request coalescer; MyMemory client instead of the provider clients |
| `crates/link`: `server`, `tls`, `store`, `auth`, `pairing`, `ws`, `mdns`, `types` | `crates/party` | Planned (M8): same HTTPS + WebSocket + PIN-pairing design, party protocol instead of Subsonic |
| `crates/desktop` | `crates/desktop` | Planned (M8.7) |
| `crates/core`: `metadata/*`, `media/hires`, `music_signature`, `native_palette`, `clock`, `lyrics/lrclib.rs`, `lyrics/models.rs`; `crates/extensions`: downloads, postprocess, files, `legacy_host`, library/reenrich/tags/share/musicbrainz backends, `binary`; `crates/mobile`: `cast`, `usb_audio`, `ffmpeg`, `hires`, `native_id3`, `network_tags`, `native_recognition`, `native_autoplay_taste`, `native_playlist*`, `native_collections`, `native_directory_stats`, `native_listing`, `library_metadata`, `metadata`, `native_lyrics_translation`; `crates/link`: `subsonic`, `catalog`, `xml`, `files`, `media`; `crates/cast` | — | Not used (no built-in providers, downloads pipeline, filesystem host API or Google Cast). `lrclib.rs` is the reference for the public sample extension (EXTENSIONS.md §8) |

## 4. Flutter (`lib/`)

### Copied (attribution header kept)
`services/backend/*`, `services/platform_bridge.dart` (method set replaced), `services/app_crash_service.dart`, `utils/logger.dart`, `widgets/app_crash_banner.dart`, `widgets/settings_group.dart`, `theme/{app_tokens,app_theme}.dart`, `models/settings.dart` and `providers/settings_provider.dart` (pattern), `app.dart` (routing pattern), `main.dart`, `constants/app_info.dart`, `l10n/supported_locales.dart`, `screens/{main_shell,setup_screen}.dart`, `screens/settings/{settings_tab,log_screen}.dart`. Copied as patterns: the dynamic-colour scheme mapping, custom-font loading, the progress-stream polling (`MainActivityProgressStreams.kt`), `NativeCrashTrace.kt`.

### Written Kalao-sized instead of copied (decided in M1–M4)
Mornye's large player and library files (`music_player_service.dart` 2,800 lines, `home_tab*` 7,000, `library_database.dart`, `player_lyrics.dart`, `listening_statistics.dart`, `backup_service.dart`, `update_checker.dart` + `apk_downloader.dart`, `share_intent_service.dart`) are written around Mornye's many decks, sources and download metadata. Kalao keeps their roles and implements smaller versions: `player_provider.dart`, `karaoke_deck.dart`, `playback_handler.dart`, `home_tab.dart`, `library_screen.dart`, `library_database.dart`, `library_queue_store.dart`, `now_playing_screen.dart`, `ruby_lyric_line.dart`, `karaoke_lyrics_view.dart`, `utils/lyrics_timeline.dart`, `stats_screen.dart` over `HistoryDatabase.stats`, `backup_service.dart`, `update_service.dart`, `screens/shared_files.dart` + `SharedFiles.kt`. The `audio_service` and `ffmpeg_kit_flutter_new_audio` forks are replaced by the published packages because their patches cover Android Auto, browsing, notification custom actions and Windows only.

### Planned, by milestone
- **M5 extensions (done):** copied `services/lyrics_language_guess.dart` and `services/secure_storage_options.dart`; written Kalao-sized: `models/extension.dart`, `services/extension_service.dart`, `providers/extension_provider.dart`, `screens/extensions/*` (tab, detail with the manifest settings form, install prompt, repositories, one priority screen for all capabilities instead of Mornye's per-capability pages), `widgets/{extension_widgets,lyrics_provider_picker}.dart`, `screens/song_detail_screen.dart`. Mornye's cover cache is not used: chosen artwork is saved into `covers/`.
- **M6 translation and stems:** `services/{lyrics_translation,lyrics_translation_alignment,lyrics_translation_languages}.dart` with a `MyMemoryClient` call through `PlatformBridge` instead of `LyricsAiClient` (keep distinct-line batching, hashing, caching, alignment); `providers/lyrics_translation_provider.dart`; `screens/settings/cache_management_page.dart`; `services/connectivity_monitor.dart`.
- **M7 scoring:** `services/audio_route_info.dart`.
- **M8 parties:** Dart `services/link/*` → `services/party/*` (host, guest client, discovery with `bonsoir`).
- **Design system, when a screen needs it:** Mornye's `app_*` and `expressive_*` widgets, `theme/{app_motion,material_expressive,material_symbols}.dart`, `utils/settings_search_catalog.dart`.

### Not used
Downloads (all `download_*`, `native_download_*`, `DownloadService*.kt`), FFmpeg re-enrich/ReplayGain/Hi-Res, network storage (SMB, WebDAV, Subsonic), Mornye Link library sync, AutoMix and autoplay, equalizer, Discord presence, Last.fm, concerts, weekly releases, listening rewind, music recognition, motion artwork, cast, USB bit-perfect output, Android Auto browsing, iOS, the Mornye glass visual style (`liquid_glass_easy`, `mornye_*` widgets), `user_profile_store` and `profile_settings_page` (no accounts), `app_remote_config_service`, the multi-deck player (`playback_deck`, `music_player_service`, `playable_media`, `content_uri_playback_cache`, `media_session_art_cache`).

## 5. Android host (Kotlin)

Copied and trimmed: `MainActivity.kt` (routing skeleton), `MainActivityCalls.kt` (Mornye's lifecycle and service calls in one file), `MainActivityProgressStreams.kt`, `BackgroundWorkService.kt`, `ForegroundServiceStartPolicy.kt`, `ForegroundWorkLock.kt`, `CoalescingWorkRefresh.kt`, `AppCrashReporter.kt`, `NativeCrashTrace.kt`, `MornyeApplication.kt` → `KalaoApplication.kt`, `src/rust/kotlin/{SelectedCoreBackend,NativeDataJobs}.kt`, `src/test/kotlin/MainActivityRoutingTest.kt`, `proguard-rules.pro` (JNA keep rules), `build.gradle.kts` (Rust task, ABI splits, signing config). Kalao's own: `MainActivityStorageCalls.kt` (SAF for backups, instead of Mornye's `MainActivitySaf*` and `SafDocument*` files), `MainActivityUpdateCalls.kt`, `SharedFiles.kt`.

Kalao's `ExtensionAuthCallbacks.kt` (M5) takes login redirects (`.kalaoext` files arrive through `SharedFiles.kt`, so `MainActivityExtensionIntents.kt` is not needed). Planned: `AudioRouteInfo.kt` (M7).

Not used: `DownloadService*`, `NativeFinalizer*`, `NativeFlac*`, `HiResPlayback`, `UsbBitPerfect*`, `UsbDirectPlayback`, `Dsd*`, `BitPerfectPcm`, `CastOutputPlugin`, `MornyeCast*`, `PlayerWidget*`, `DownloadQueueWidgetProvider`, `LinkConnectionService`, `LocalNetworkPlugin` (replaced by party calls), `MusicHapticsPlugin`, `NativeAudio` (replaced by Rust audio), `AudioOpenBridge`, `SharedEngineChannels`.

## 6. Dependencies

Kalao keeps Mornye's pinned versions for every dependency it shares (LIBRARIES.md), so known-good combinations (e.g. `flutter_secure_storage 10.3.4` migration constraints, `rquickjs 0.14.0`, the `rustix` patch) carry over. Renovate is configured as in Mornye.
