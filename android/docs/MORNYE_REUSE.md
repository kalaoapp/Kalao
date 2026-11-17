# Reusing Mornye

Kalao is built on Mornye's code wherever Mornye already solves the problem. This file says, per area, what is **copied** (renamed only), **adapted** (copied, then changed for karaoke), or **not used**. Paths are relative to the Mornye repo root (`mornyeapp/Mornye`).

## 1. Licence and attribution (do this with every copied file)

- Mornye is **LGPL-3.0-only** (`LICENSE`, `COPYING`, `NOTICE`: "Copyright 2026 zarzet"). LGPL-3.0 lets the code be used in a GPL-3.0 work, so Kalao ships as **GPL-3.0-only**.
- Keep Mornye's copyright line. Every copied file gets a header: `// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.` Rust files use `//!` or `//` the same way; Kotlin uses `//`.
- Kalao's `NOTICE` lists Mornye and every vendored third-party package (`third_party/*/LICENSE` and `MORNYE_PATCHES.md` files are kept as they are, with a `KALAO_PATCHES.md` added next to them if Kalao changes them further).
- `assets/licenses/` and the in-app Licences page (Mornye's `about_page.dart`) include Mornye.
- Rename identifiers when copying: `mornye` → `kalao`, `Mornye` → `Kalao`, `com.zarz.mornye` → `com.brinsley.kalao`, `com.mornye.backend` → `com.brinsley.kalao.backend`, `mornye_mobile` → `kalao_mobile`, `MORNYE_*` env vars → `KALAO_*`. Do not keep Mornye's branding, icons, fonts or brand assets.
- Drop Mornye's Go-compatibility code paths ("retired Go backend" contracts, `legacy_host`, `native_backup/legacy.rs`) unless a copied module needs them to compile; Kalao has no legacy formats to read.

## 2. Repository and tooling

| Mornye | Kalao | Action |
| --- | --- | --- |
| `.editorconfig`, `.gitattributes`, `analysis_options.yaml`, `devtools_options.yaml`, `renovate.json` | `android/` (and root for editorconfig/gitattributes) | Copy |
| `.fvmrc` (`flutter 3.47.8`) | `android/.fvmrc` | Copy |
| `l10n.yaml` | `android/l10n.yaml` | Copy |
| `cliff.toml` (changelog) | root | Copy |
| `crowdin.yml` | — | Not used for now (four launch languages are translated by hand) |
| `.github/workflows/ci.yml` | root | Adapt: drop iOS and Discord jobs; keep Flutter format/analyze/test, `check_rust_backend.sh`, Android assemble + `testDebugUnitTest` + APK payload audit; add gitleaks and the no-extensions-tracked check |
| `.github/workflows/release.yml` | root | Adapt: Android only; APK splits, V1–V4 signing and verification, payload audit, symbol retention, GitHub Release with SHA-256 checksums |
| `.github/workflows/desktop.yml` | root | Later (desktop) |
| `.github/ISSUE_TEMPLATE/*`, `PULL_REQUEST_TEMPLATE.md`, `actionlint.yaml` | root | Adapt (drop download-issue template; add lyrics/sync template) |
| `.github/FUNDING.yml` | root | Adapt: `ko_fi: brinsley` |
| `scripts/prepare_flutter_sdk.dart` and `patches/flutter/` (Mornye's Flutter framework patch) | — | Not used: Kalao builds with stock Flutter |
| `scripts/build_rust_backend.sh`, `check_rust_backend.sh`, `build_android.sh`, `check_backend_apk.py`, `check_android_statx.sh`, `test_build_android.py`, `test_check_backend_apk.py`, `prepare_flutter_sdk.dart` | `scripts/` | Copy and rename; drop iOS/Discord/SMB/macOS/Windows scripts until desktop |
| `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` | root | Adapt |

## 3. Rust workspace

| Mornye | Kalao | Action |
| --- | --- | --- |
| `rust_backend/Cargo.toml`, `rust-toolchain.toml`, `NOTICE`, `README.md` | `rust_backend/` | Copy structure; replace members and dependency list (LIBRARIES.md) |
| `rust_backend/vendor/rustix-1.1.6` + `vendor/README.md` | same | Copy (Android `statx` fix). `libusb1-sys` and `cap-primitives` patches only if a copied crate needs them |
| `crates/network` | `crates/network` | **Copy** unchanged |
| `crates/bindgen` | `crates/bindgen` | **Copy** unchanged |
| `crates/core`: `json` helpers, `filename`, `tags`, `cover`, `lyrics/{lrc,matching,file,payloads/ttml,errors,config}`, `progress`, `isrc` | `crates/core` | **Copy** these modules |
| `crates/core`: `metadata/deezer`, `metadata/musicbrainz`, `media/hires`, `music_signature`, `native_palette`, `clock`, `lyrics/lrclib.rs`, `lyrics/models.rs` (Spotify/YouTube/Netease schemas) | — | Not used (built-in providers are not allowed; content comes from extensions). `lrclib.rs` becomes the public sample extension instead (EXTENSIONS.md §8) |
| `crates/providers` | `crates/providers` | Adapt: keep the crate shape and request coalescer; replace provider clients with the MyMemory client |
| `crates/extensions`: `runtime`, `host`, `manifest`, `package`, `repository`, `storage`, `manager/{install,lifecycle,info,providers,metadata}`, `network_host`, `crypto`, `crypto_host`, `redact`, `logging`, `provider.rs`, `provider.js`, `prelude.js`, `backend/{lyrics,metadata,health}`, `auth`, `environment`, `resolution` | `crates/extensions` | **Copy**, then adapt capabilities to Kalao's (`lyrics`, `metadata`, `audio`, `artwork`) |
| `crates/extensions`: `download`, `backend/downloads`, `manager/downloads`, `manager/postprocess`, `files`, `legacy_host`, `backend/{library,reenrich,tags,share,musicbrainz}`, `signed_session` (unless needed by `auth`), `binary` | — | Not used (no downloads pipeline, no filesystem host API) |
| `crates/mobile`: `lib.rs` scaffolding, `cancellation`, `data_jobs`, `logging`, `progress`, `extensions`, `manager`, `repository`, `lyrics`, `native_lyrics/{lrc,ttml,text}`, `native_backup/{archive,collections}`, `native_cache`, `native_library/{path_keys,dart_date}`, `tags`, `filename` | `crates/mobile` | **Copy** and trim to Kalao's method table |
| `crates/mobile`: `cast`, `usb_audio`, `ffmpeg` (command queue), `hires`, `native_id3`, `network_tags`, `native_recognition`, `native_autoplay_taste`, `native_playlist*`, `native_collections`, `native_directory_stats`, `native_listing`, `library_metadata`, `metadata`, `native_lyrics_translation` | — | Not used (`ffmpeg` is revisited only if import conversion needs Rust-side orchestration) |
| `crates/link`: `server`, `tls`, `store`, `auth`, `pairing`, `ws`, `mdns`, `types` | `crates/party` | **Adapt**: same HTTPS + WebSocket + PIN-pairing design, party protocol instead of Subsonic |
| `crates/link`: `subsonic`, `catalog`, `xml`, `files`, `media` | — | Not used |
| `crates/desktop` | `crates/desktop` | Copy when `desktop/` starts |
| `crates/cast` | — | Not used (Google Cast needs Play services) |

## 4. Flutter (`lib/`)

### Copied (rename only)
- **Backend:** `services/backend/*`, `services/platform_bridge.dart` + `platform_bridge/` (method set replaced), `utils/progress_stream_poller.dart`.
- **Infrastructure:** `utils/logger.dart`, `services/native_log_source.dart`, `services/app_crash_service.dart`, `models/app_crash_report.dart`, `widgets/app_crash_banner.dart`, `services/secure_storage_options.dart`, `services/preference_blob_store.dart`, `services/sqlite_helpers.dart`, `sqlite_long_text.dart`, `sqlite_native_snapshot.dart`, `services/connectivity_monitor.dart`, `services/notification_service.dart`, `services/app_navigation_service.dart`, `services/shell_navigation_service.dart`, `services/app_orientation.dart`, `utils/periodic_async_task.dart`, `utils/ttl_cache.dart`, `utils/user_facing_error.dart`, `utils/file_access.dart`, `utils/hash_utils.dart`, `utils/string_utils.dart`, `utils/adaptive_layout.dart`, `utils/nav_bar_inset.dart`, `utils/android_tv.dart`.
- **Theme and design system:** `theme/{app_tokens,app_theme,app_motion,dynamic_color_wrapper,material_expressive,material_symbols}.dart`; widgets `app_*` (alert dialog, bottom sheet, buttons, checkbox, chip, content card, icon, loading/progress indicators, menu button, refresh indicator, search field, shape, slider, sliver header, snack bar, switch, text field), `expressive_*`, `settings_group.dart`, `error_card.dart`, `lazy_tab_view.dart`, `scroll_edge_fade.dart`, `no_scrollbars.dart`, `overflow_marquee.dart`, `swipe_delete_dismissible.dart`, `selection_*`, `destructive_selection_button.dart`, `discard_changes_dialog.dart`, `tool_button_group.dart`.
- **Settings infrastructure:** `models/settings.dart` pattern, `providers/settings_provider.dart` pattern, `utils/settings_search_catalog.dart`, `screens/settings/{settings_tab,app_settings_page,appearance_settings_page,keyboard_shortcuts_page,log_screen,cache_management_page,provider_priority_list_page,provider_priority_page,lyrics_provider_priority_page,metadata_provider_priority_page}.dart`, `widgets/{priority_settings_scaffold,reorderable_priority_item,lyrics_size_setting,custom_font_setting}.dart`, `services/custom_font_service.dart`.
- **App flow:** `app.dart` routing pattern, `screens/{main_shell,setup_screen,setup_steps,tutorial_screen,whats_new_screen}.dart`, `services/setup_progress_store.dart`.
- **Extensions UI:** `providers/{extension_provider,extension_provider_priority,repo_provider}.dart`, `models/extension.dart`, `screens/repo_tab.dart`, `screens/repo/extension_details_screen.dart`, `screens/settings/{extensions_page,extension_detail_page}*.dart`, `controllers/{extension_action_forms,extension_auth_launcher}.dart`, `widgets/{extension_row,extension_health,extension_icon_image,extension_repo_card,extension_storage_setting}.dart`, `services/extension_storage_service.dart`, `utils/extension_session_callback.dart`.
- **Lyrics:** `utils/{lyrics_parser,lyrics_timeline,synced_lyrics_scroll,lyrics_draft,lyrics_metadata_helper,lyrics_provider_names}.dart`, `widgets/{player_lyrics,player_lyrics_controls,player_lyrics_line_style,player_lyrics_section,player_lyrics_word_sweep,aligned_lyric_pronunciation,lyric_blur,lyric_gap_indicator,lyric_scroll_motion,lyric_supplement_transition,lyrics_editor_sheet,lyrics_options_button,lyrics_provider_picker,lyrics_screen_awake,lyrics_text_scale}.dart`, `services/{lyrics_language_guess,lyrics_translation,lyrics_translation_alignment,lyrics_translation_languages,player_lyrics_persistence}.dart`, `providers/lyrics_translation_provider.dart`, `screens/settings/lyrics_settings_page.dart`.
- **Player:** `services/{playback_deck,music_player_service (+ parts),music_player_runtime,playable_media,playback_metadata,playback_session_restore,playback_session_writer,playback_resume_store,playback_notification,playback_output_volume,media_session_art_cache,system_volume_service,content_uri_playback_cache,audio_route_info,audio_file_open_service}.dart`, `providers/{music_player_provider,playback_provider,playback_notification_provider,system_volume_provider}.dart`, `third_party/audio_service` (fork with `MORNYE_PATCHES.md`), widgets `mini_player`, `player_playback_controls`, `playback_seek_slider`, `expressive_seek_track`, `expressive_playback_transport`, `playback_time_builder`, `player_queue_sheet`, `player_queue_dismissible`, `player_track_swipe`, `player_volume_control`, `material_player_layout`, `material_player_backdrop`, `player_artwork`, `cached_cover_image`, `now_playing_indicator`, `audio_output_button`, `playback_feedback`, `smoothed_progress`.
- **Library:** `services/{library_database,library_schema,library_row_mapper,library_search,library_lyrics_search,library_queue_store,library_native_adapter,library_cleanup,library_duplicates,history_database,history_schema,history_row_mapper,history_maintenance,app_state_database,cover_store,cover_cache_manager,audio_metadata_mapper,track_file_resolver}.dart`, `providers/{local_library_provider (+ parts),library_browse_provider,library_search_provider,library_counts_provider,library_lyrics_search_provider,recent_access_provider,track_provider}.dart`, `screens/{home_tab*,queue_tab*,mornye_library_screen → library_screen,track_metadata_*}.dart` (trimmed), `controllers/{selection_mode_mixin,open_audio_controller,local_playback,player_track_navigation,track_history_snapshot}.dart`.
- **Stats:** `services/listening_statistics.dart`, `providers/listening_statistics_provider.dart`, `screens/listening_statistics_screen.dart`.
- **Backup:** `services/backup_service.dart`, `collection_restore_codec.dart`, `screens/settings/backup_restore_page.dart`.
- **Updates and about:** `services/{update_checker,apk_downloader,update_progress_notifications}.dart`, `widgets/update_dialog.dart`, `screens/settings/{about_page,donate_page}.dart` (donate page reduced to the single Ko-fi link), `widgets/donate_icons.dart` (Ko-fi icon only), `assets/licenses/`.
- **Share intents and file open:** `services/share_intent_service.dart` (open `.kalaoext`, `.kalaobackup`, `.lrc`, audio), `receive_sharing_intent`. As built (M4.12): not copied; `SharedFiles.kt` collects VIEW/SEND URIs and `screens/shared_files.dart` routes them (`.kalaoext` joins in M5).

### Adapted
- `services/lyrics_translation.dart`: swap `LyricsAiClient` for a `MyMemoryClient` call through `PlatformBridge.translateLyrics`; keep distinct-line batching, hashing, caching, alignment.
- `utils/lyrics_parser.dart`: `LyricLine` gains `layers` and `section`; the parser accepts Kalao's layered import format (POC) in addition to LRC/TTML.
- `services/music_player_service.dart`: deck factory always returns `KaraokeDeck`; AutoMix, autoplay, cast, gapless-crossfade, equalizer and ReplayGain parts removed.
- `screens/now_playing_screen.dart`: Learn and Karaoke layouts, stem mix controls, key/tempo, loop controls.
- `services/backup_service.dart`: Kalao categories (library, lyrics and annotations, history and scores, favorites, queue, settings, extensions, optional media).
- `crates/link` → `crates/party` and Dart `services/link/*` → `services/party/*` (host, guest client, discovery with `bonsoir`).

### Decided while implementing M1
The large Mornye player and library files (`music_player_service.dart` 2,800 lines, `home_tab*` 7,000, `library_database.dart`, `player_lyrics.dart`, `core::tags` 2,700) are written around Mornye's many decks, sources and download metadata. M1 keeps their roles and patterns but implements Kalao-sized versions (`player_provider.dart`, `karaoke_deck.dart`, `home_tab.dart`, `library_database.dart`, `now_playing_screen.dart`, Symphonia metadata for `probeAudio`). The `audio_service` and `ffmpeg_kit_flutter_new_audio` forks are replaced by the published packages because their patches cover Android Auto, browsing, notification custom actions and Windows only. Copied as planned: `NativeCrashTrace.kt`, the progress-stream polling pattern (`MainActivityProgressStreams.kt`), the dynamic-colour scheme mapping, the custom-font loading pattern.

### Not used
Downloads (all `download_*`, `native_download_*`, `DownloadService*.kt`), FFmpeg re-enrich/ReplayGain/Hi-Res, network storage (SMB, WebDAV, Subsonic), Mornye Link library sync, AutoMix and autoplay, equalizer, Discord presence, Last.fm, concerts, weekly releases, listening rewind, music recognition, motion artwork, cast, USB bit-perfect output, Android Auto browsing, iOS, the Mornye glass visual style (`liquid_glass_easy`, `mornye_*` widgets), `user_profile_store` and `profile_settings_page` (no accounts), `app_remote_config_service`.

## 5. Android host (Kotlin)

Copied: `MainActivity.kt` (routing skeleton), `MainActivityLifecycleCalls.kt`, `MainActivityServiceCalls.kt`, `MainActivityProgressStreams.kt`, `MainActivitySmallChannels.kt`, `MainActivityExtensionIntents.kt`, `MainActivitySafCalls.kt`, `MainActivitySafIo.kt`, `MainActivitySafLeases.kt`, `MainActivitySafTreePicker.kt`, `SafDocument*`, `ExtensionAuthCallbacks.kt`, `BackgroundWorkService.kt`, `ForegroundServiceStartPolicy.kt`, `ForegroundWorkLock.kt`, `CoalescingWorkRefresh.kt`, `AppCrashReporter.kt`, `NativeCrashTrace.kt`, `AudioRouteInfo.kt`, `AudioOpenBridge.kt`, `SharedEngineChannels.kt`, `MornyeApplication.kt` → `KalaoApplication.kt`, `src/rust/kotlin/*`, `src/test/kotlin/MainActivityRoutingTest.kt`, `proguard-rules.pro` (JNA keep rules), `build.gradle.kts` (Rust task, ABI splits, signing config from env).

Not used: `DownloadService*`, `NativeFinalizer*`, `NativeFlac*`, `HiResPlayback`, `UsbBitPerfect*`, `UsbDirectPlayback`, `Dsd*`, `BitPerfectPcm`, `CastOutputPlugin`, `MornyeCast*`, `PlayerWidget*`, `DownloadQueueWidgetProvider`, `LinkConnectionService`, `LocalNetworkPlugin` (replaced by party calls), `MusicHapticsPlugin`, `NativeAudio` (replaced by Rust audio).

## 6. Dependencies

Kalao keeps Mornye's pinned versions for every dependency it shares (LIBRARIES.md), so known-good combinations (e.g. `flutter_secure_storage 10.3.4` migration constraints, `rusqlite 0.41.1`, `rquickjs 0.14.0`, the `rustix` patch) carry over. Renovate is configured as in Mornye.
