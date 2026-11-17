# Roadmap

Milestones are ordered by dependency; each ends with a tested build on `main` and a tag. Feature numbers refer to FEATURES.md; "Mornye" names the source to copy or adapt (MORNYE_REUSE.md); design details are in IMPLEMENTATION.md (§ numbers below). Every feature in FEATURES.md appears in exactly one milestone; the coverage table at the end checks that.

## M0 Foundations — implemented (2026-11-15)

Status: ✅ built and tested locally (Rust: fmt, clippy, 60 tests; script tests); ⏳ Flutter analyze/test and the Android build run in CI on the first push (this machine has no Flutter or Android SDK).

| # | Task | Status | Mornye source |
| --- | --- | --- | --- |
| M0.1 | Root tooling: `.editorconfig`, `.gitattributes`, `cliff.toml`, `renovate.json` (automerge off), `NOTICE` (Kalao + Mornye attribution), `CONTRIBUTING.md`, issue templates (bug, lyrics, feature), PR template, `FUNDING.yml` (`ko_fi: brinsley`) | ✅ | root files |
| M0.2 | `rust_backend/` workspace: `Cargo.toml` (members `core`, `network`, `mobile`, `bindgen`), `rust-toolchain.toml`, workspace lints, `README.md` crate map, `Cargo.lock` seeded from Mornye's; licence `GPL-3.0-only` | ✅ (`providers` moves to M6.7; the `rustix` patch is added with the first crate that uses `rustix`, M1.5) | `rust_backend/*` |
| M0.3 | `crates/network` and `crates/bindgen` copied and renamed | ✅ | `crates/network`, `crates/bindgen` |
| M0.4 | `crates/core`: JSON helpers, text, XML depth check, matching, cancellation (domains `DataJob`, `ExtensionRequest`), lyrics (`lrc`, `matching`, `errors`, `json`, `payloads` incl. TTML) with Mornye's tests and fixture; built-in provider config, LRCLIB, provider schemas and Paxsenix credits removed | ✅ (`filename`, `tags`, `cover` move to M1.5; `progress` to M6.1) | `crates/core` |
| M0.5 | `crates/mobile`: UniFFI scaffolding; `invoke_application(method, args_json)` with a sorted method table (`initBackend`, `getBackendInfo`, `getLogs`, `clearLogs`, `setLoggingEnabled`); `run_native_data_job` (`hash_file`); cancellation registry; process-wide log buffer; `uniffi.toml` (`com.brinsley.kalao.backend`, `kalao_mobile`) | ✅ | `crates/mobile` |
| M0.6 | `scripts/build_rust_backend.sh` (host + android; arm64, armv7, x86_64; Linux, macOS and Windows hosts), `check_rust_backend.sh`, `build_android.sh`, `check_backend_apk.py` (ELF, ABI set, 16 KB `PT_LOAD` alignment) + `test_check_backend_apk.py` | ✅ | `scripts/` |
| M0.7 | Flutter project `android/` (`com.brinsley.kalao`, Flutter 3.47.8 via `.fvmrc`), `pubspec.yaml` (M0 subset), Mornye's `analysis_options.yaml` and `l10n.yaml` | ✅ | `pubspec.yaml`, `lib/` layout |
| M0.8 | Kotlin host: `KalaoApplication`, `MainActivity` routing (`nativeBackendMethods` + `MainActivityRoutingTest`), `MainActivityCalls.kt` (screen awake, background work, crash report), `SelectedCoreBackend.kt` (CoreBackend over UniFFI/JNA, JSON argument conversion), `NativeDataJobs.kt`, `__json_file` spill + stale-file sweep, `BackgroundWorkService` + `ForegroundWorkLock` + `CoalescingWorkRefresh` + `ForegroundServiceStartPolicy`, `AppCrashReporter`; Gradle `buildRustBackend` before `preBuild`, JNA, ProGuard rules, ABI splits, signing from `key.properties`; adaptive launcher icon; HTTPS-only network config; Android backup disabled | ✅ (progress `EventChannel`s arrive with the first stream, M1.1; audio_service's cached engine with M1.4; `NativeCrashTrace` with M1.1) | `android/app/*` |
| M0.9 | Dart backend layer: `services/backend/{backend_channel,method_channel_backend}.dart`, `platform_bridge.dart` (typed calls, isolate JSON decode, `__json_file` spill) | ✅ (`RustFfiBackend` with `desktop/`) | `lib/services/backend`, `platform_bridge.dart` |
| M0.10 | App shell: `main.dart` (error handlers, settings, engine check), `app.dart` (go_router, `initialLocationForAppState`), `main_shell.dart` (Home, Library, Queue, Extensions placeholders + Settings), `setup_screen.dart` (language, theme) | ✅ (tutorial and What's New in M3.8; permission steps with the features that need them) | `app.dart`, `screens/main_shell.dart`, `setup_*` |
| M0.11 | Theme layer: `app_tokens.dart`, `app_theme.dart` (Material 3; seed replaced by the brand palette in M1, BRANDING.md); widgets `settings_group`, `empty_state`, `app_crash_banner` | ✅ (Material You moves to M1.14: `dynamic_color` 2.x uses the separate `material_ui` package, so it comes with Mornye's `dynamic_color_wrapper.dart`; further design-system widgets are copied when a screen needs them) | `lib/theme`, `widgets/` |
| M0.12 | l10n: `app_en.arb`, `app_zh.arb` (Simplified), `app_zh_Hant.arb`, `app_ja.arb`; `supported_locales.dart`; language picker | ✅ | `lib/l10n` |
| M0.13 | Settings: `models/settings.dart` (hand-written JSON, tolerant of unknown keys), `settings_provider` (shared_preferences), `settings_tab` (appearance, diagnostics, about with engine info and licences) | ✅ (`json_serializable` is introduced when models need code generation; `settings_search_catalog`, `secure_storage_options` and `preference_blob_store` with their first users in M4–M6) | settings files |
| M0.14 | Logging and crash capture: `AppLogger` + `LogBuffer` with Mornye's redaction rules (plus MyMemory's `de=`), Rust log buffer merged in `log_screen` (copy, clear), `app_crash_service` + `AppCrashReporter.kt` (Dart errors saved as context only; banner after a real crash) | ✅ (log export/share and the GitHub issue link in M4.8) | logging files |
| M0.15 | CI `ci.yml`: gitleaks; fail if `*.kalaoext`, `android/extensions/` or `poc-webapp/` is tracked; Dart format + analyze + test; `check_rust_backend.sh` + script tests; Android `assembleDebug` + `testDebugUnitTest`, release APK build + audit + `apksigner`/`zipalign` checks | ✅ | `.github/workflows/ci.yml` |
| M0.16 | `release.yml`: tag `vX.Y.Z` (checked against pubspec) → arm64, arm32, x86_64 and universal APKs, V1–V4 signing and verification, payload audit, symbols artifact, GitHub Release with `SHA256SUMS.txt` and `git-cliff` changelog | ✅ (needs the `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEYSTORE_PASSWORD` secrets; first run at M3.9) | `.github/workflows/release.yml` |

Tests added: Rust `backend` (method table sorted and dispatched, init, errors), `data_jobs`, `logging`; Kotlin `MainActivityRoutingTest`; Dart `platform_bridge_test` (decode, spill, errors), `settings_test`, `logger_test` (redaction, ring), `app_test` (setup → shell, engine info, logs, crash banner, locale).

**Exit:** `getBackendInfo` round-trips Dart → Kotlin → Rust on an emulator and a device; logs from Rust appear in the log screen; CI is green; `release.yml` produces signed APKs once the signing secrets exist.

## M1 Local player — implemented (2026-11-15)

Status: ✅ built and tested locally (Rust: fmt, clippy, all workspace tests incl. 12 engine tests on rendered buffers and the POC fixtures; `libkalao_mobile.so` cross-compiles for arm64; Flutter analyze clean, 34 Dart tests); ⏳ the on-device exit checks (headset buttons, backgrounding, real decoding on AAudio) need an emulator or device run.

| # | Task | Features | Status | Source / § |
| --- | --- | --- | --- | --- |
| M1.1 | `crates/audio` (`kalao-audio`): Symphonia decoders, rubato (`FastFixedIn`, cubic), `ringbuf` SPSC rings (≈0.5 s), one decoder thread per source, mixer with ramped gains (10 ms) and an equal-power original/instrumental crossfade (150 ms), soft limiter, seek with flush (worker + consumer locks), clock with output-latency correction from cpal timestamps, completion; cpal output thread with rebuild after device errors; `player_position_stream` (`MainActivityProgressStreams.kt`, polls `playerState`); `NativeCrashTrace` + startup capture of native tombstones (`AppCrashReporter.captureNativeExit`) | 1.1, 1.2, 1.3 | ✅ (`PerformanceMode::LowLatency` is not exposed by cpal 0.16: M7) | IMPLEMENTATION §2 |
| M1.2 | Player methods `playerLoad`, `playerPlay`, `playerPause`, `playerStop`, `playerSeek`, `playerSetVolume`, `playerSetStemGains`, `playerSwitchTrack`, `playerState` | 1.1–1.3 | ✅ (`playerSetKey/Tempo/Loop` with M3.1/M3.2; `playerPrefetch` with the queue, M3.4) | §1 |
| M1.3 | `KaraokeDeck` (engine commands + interpolated position) and `PlayerController` (load, play/pause/seek, switch, vocal blend, history rows, session restore for "Continue singing") | 1.1 | ✅ (Mornye's multi-deck `music_player_service.dart` is not copied: Kalao has one deck; see §2) | `karaoke_deck.dart`, `player_provider.dart` |
| M1.4 | Media session: `audio_service` 0.18.19 from pub.dev with `MainActivity : AudioServiceFragmentActivity` (cached engine), `KalaoAudioHandler` (notification, lock screen, artwork, headset buttons), `audio_session` focus (duck, pause, resume after transient loss) and becoming-noisy pause | 1.5 | ✅ (fork not needed, LIBRARIES §2) | `playback_handler.dart` |
| M1.5 | Import: `file_picker` → staging copy → `hash_file` → `media/<sha256>.<ext>` (once per hash) → `probeAudio` (Symphonia tags, cover, duration, codec) → `pairImportFiles` (`core::pairing`: name similarity, instrumental markers incl. 伴奏/カラオケ/off vocal, ±2 s) → pairing sheet (titles, instrumental, lyrics file, include) with duplicate detection by hash | 1.7 | ✅ (Mornye's `core::tags`/`cover`/`filename` and the `rustix` patch are not needed: see §3) | §3 |
| M1.6 | Symphonia codecs (MP3, AAC/M4A, ALAC, FLAC, Vorbis, WAV); FFmpegKit (`ffmpeg_kit_flutter_new_audio` 2.5.7) converts the rest to FLAC once at import | 1.6 | ✅ | `main.dart` `_convertWithFfmpeg` |
| M1.7 | `library_schema.dart` (`song`, `media_file`, `lyric_doc`, `lyric_annotation`, `song_search`; history `play`; app state `playback_session`, `recent_access`), `library_database.dart`, `history_database.dart`, `library_provider.dart` | 6.1 | ✅ (`favorite`, `melody`, `stem_job`, `backup_run`, `queue_item` arrive with their features) | `library_*` |
| M1.8 | Home: search, Continue singing, Recently played, Recently added; Library: list/grid, sort (added, title, artist), selection mode with delete (removes unused media files); mini player | 6.1 | ✅ | `home_tab.dart`, `library_screen.dart` |
| M1.9 | Search keys via `rebuildSearchKeys` (`core::search_keys`): normalised title/artist, toneless pinyin and initials, kana romaji; prefix-ranked substring search | 6.2 (local) | ✅ (romaji for kanji needs the Japanese analyser, M3.6) | `library_search.dart`, §3 |
| M1.10 | Lyrics import (paste, `.txt`/`.lrc` file, embedded tags, lyrics file paired at import); `parseLyrics` (`core::lyrics::doc`: LRC with several time tags and `[offset:]`, plain text) | 2.1 | ✅ | `lyrics_import_sheet.dart` |
| M1.11 | Sections and normalisation (`core::sections`, POC marker lists for en/zh/ja/ko/es/fr/de/pt and its bracket forms) | 2.2 | ✅ | §4 |
| M1.12 | `core::annotate::pinyin` with `pinyin_pro` (context polyphones, tone marks, er-hua merge, per-character UTF-16 segments); POC diacritic, 而, bracket and whitespace cases pass | 2.3 | ✅ | §4 |
| M1.13 | Now playing: layered lyrics (`ruby_lyric_line.dart`), section labels, pinyin toggle, seek slider, transport, original ↔ instrumental, vocal-guide slider, manual line stepping (tap, ↑/↓, buttons), keyboard (Space, ←/→ 5 s) | 1.2, 1.3, 2.1, 2.7 | ✅ (Mornye's player layout widgets are not copied; the screen is Kalao-sized) | `now_playing_screen.dart` |
| M1.14 | Material You (`dynamic_color` + `material_ui`, toggle), lyric sizes S–XXL, custom lyric font (FontLoader), strings for en, zh-Hans, zh-Hant, ja | 9.1 (launch set), 9.2 | ✅ | `app_theme.dart`, `custom_font_service.dart` |
| M1.15 | Accessibility: tooltips/labels on every icon button, ruby lines read as text + readings, slider value semantics, section headers, text scale unclamped, reduced motion disables lyric scroll animation, inactive lyrics use `onSurfaceVariant` for contrast | 9.4 | ✅ (TalkBack pass on a device is part of the exit check) | — |

Tests added: Rust `kalao-audio` (stem sync by phase cancellation, seek frame accuracy, crossfade curve, gain ramps, resampled duration and completion, probe), `core` (sections, pinyin, search keys, pairing, lyric documents), `mobile` (player/lyrics/import methods, `rebuildSearchKeys`); Dart `library_test` (schema, lyrics versions and layers, search ranking, history, import pairing/copy/convert/delete/duplicates, ruby units, active line), `player_test` (deck interpolation, player flow, Now playing with pinyin and stepping, search by pinyin).

**Exit:** an imported original + instrumental pair plays, switches without losing position, blends, survives backgrounding and headset controls; Chinese lyrics show pinyin; POC pinyin/bracket/section fixtures pass; search by pinyin works.

## M2 Timed lyrics — implemented (2026-11-17)

Status: ✅ built and tested locally (Rust: fmt, clippy, all workspace tests incl. the eLRC round trip, TTML import and the engine click-track timing test; Flutter analyze clean, 48 Dart tests); ⏳ the on-device exit check (`integration_test/lyrics_timing_test.dart`, and the editor used by hand on a real song) needs an emulator or device run.

| # | Task | Features | Status | Source / § |
| --- | --- | --- | --- | --- |
| M2.1 | Timed model: line start/end, word timing (`LyricWord` with its range in the line text), voices (`v1`/`v2`, backing `bg`), line translation, `timed` flag, per-song offset; document JSON version 2; active line from the interpolated engine clock (`KaraokeDeck.position`, song time × tempo), swept characters per frame (`utils/lyrics_timeline.dart`) | 2.6 | ✅ (Mornye's `lyrics_timeline.dart`/`synced_lyrics_scroll.dart` are not copied: Kalao-sized versions, as in M1; a Rust `core::sync` mirror is added when a Rust consumer needs it, M7/M8) | `models/lyrics.dart`, `utils/lyrics_timeline.dart` |
| M2.2 | `core::lyrics::doc`: LRC and enhanced LRC (word tags in both common styles, line ends, `v1:`/`v2:` voices, `[bg:…]` rows) import; TTML import through Mornye's Apple payload reader (word timing, duet sides, backing vocals, head translations); `exportLyrics(doc, format)` to LRC (line starts) and enhanced LRC (round-trips line and word timing, ends, sections, breaks, voices); `.ttml` in the import pickers and pairing | 2.8 | ✅ | §4 |
| M2.3 | Sweep over the active line: word by word with word timing, linear over the line duration otherwise (capped at 10 s); `SweepText` clips a highlight layer to the sung characters and repaints without rebuilding; works under ruby (pinyin) too; setting "Karaoke sweep" | 2.13 | ✅ (Mornye's `player_lyrics_word_sweep.dart` is not copied) | `ruby_lyric_line.dart` |
| M2.4 | Tap-to-time sync editor (`/player/sync`): line and word modes (words = one per CJK character, else per word), hold to stamp the end, 50/75/100% speed while timing (`playerSetTempo`), tap-latency setting (default 40 ms; output latency is already in the engine clock), nudge ±10/±50 ms, replay line, undo, save as a new `lyric_doc` version (`userEdited`, layers kept), export LRC/eLRC | 2.9 | ✅ (`playerSetTempo` is a resampler speed change, so the pitch drops with the speed; M3.1's Signalsmith Stretch keeps the pitch behind the same method) | `lyrics_sync_editor_controller.dart`, `lyrics_sync_screen.dart`, §4 |
| M2.5 | Offset control in the lyrics options sheet (±5 s in 50 ms steps, reset), stored in the current lyric version; LRC `[offset:]` is read and written | 2.6 | ✅ | `lyrics_options_sheet.dart` |
| M2.6 | Timing accuracy (±30 ms): engine test on rendered click tracks (through the resampler, at tempo 1 and 0.5); Dart test of the deck's interpolation against a simulated 30 Hz engine; on-device `integration_test/lyrics_timing_test.dart` (click track + LRC on the real engine) | 2.6 | ✅ tests written and the host ones pass; ⏳ the device test has not been run | §17 |

Tests added: Rust `core::lyrics::doc` (eLRC styles, round trip, LRC export, TTML), `mobile` (`exportLyrics`), `kalao-audio` (tempo, click-track timing); Dart `lyrics_test` (model, sweep maths, word splitting, editor, timing model, import/offset/export, Now playing sweep and offset, sync editor flow).

**Exit:** LRC import auto-follows within ±30 ms; the editor produces enhanced LRC that round-trips.

## M3 Modes, first release

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M3.1 | Signalsmith Stretch in the engine bus; key ±6 semitones, tempo 50–150%, bypass when neutral; UI controls | 1.4 | §2 |
| M3.2 | Learn mode: loop current line, A–B repeat, slow-down presets, line stepping, translation slot | 3.1 | §5 |
| M3.3 | OG Karaoke mode: large two-line layout, word sweep, countdown dots, keep-awake, next-singer banner | 3.2 | `lyric_gap_indicator.dart`, `lyrics_screen_awake.dart` |
| M3.4 | Queue: add/reorder/remove, singer names, mode per entry, persistence | 6.5 | `library_queue_store.dart`, `queue_tab*`, `app_state_database.dart` |
| M3.5 | Hardware keyboard and gamepad shortcuts (Space, ←/→ 5 s, ↑/↓ line, S switch track, L loop, ? help) and the help sheet | 9.3 | `keyboard_shortcuts_page.dart` |
| M3.6 | `core::annotate::japanese` (lindera readings → furigana, wana_kana romaji, `romanizationWords`) | 2.4 | §4 |
| M3.7 | `core::annotate::chinese_variant` (OpenCC s2t/t2s/s2tw/s2hk); Trad/Simp layers and setting | 2.5 | §4 |
| M3.8 | Tutorial and What's New screens with Kalao content | — | `tutorial_screen.dart`, `whats_new_screen.dart` |
| M3.9 | **First GitHub Release** (`v0.1.0`) via `release.yml` | — | `release.yml` |

**Exit:** Learn and OG Karaoke modes usable end to end in zh/ja/en songs; v0.1.0 APKs on GitHub Releases with checksums.

## M4 Library, backup, about

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M4.1 | Favorites (loved songs) | 6.3 | loved-tracks pattern |
| M4.2 | History rows (`play`) with mode, score, singer; stats screen | 6.7 | `listening_statistics*.dart`, `history_*` |
| M4.3 | Backup export: categories, optional media, SAF target, archive in `native_backup::archive` data job | 7.1, 7.2 | `backup_service.dart`, `native_backup/archive` |
| M4.4 | Restore: inspect + preview, merge and replace modes, safety backup, database republish | 7.3 | `backup_restore_page.dart`, `LibraryNativeAdapter` |
| M4.5 | Scheduled backup (due-check on start/resume, keep last N, `backup_run` log) | 7.4 | `periodic_async_task.dart` |
| M4.6 | Secrets excluded from backups; restored extensions prompt for secrets | 7.5 | `secure_storage_options.dart` |
| M4.7 | POC import: export script (private POC repo) + `pocImport` data job | 7.6 | §12 |
| M4.8 | Diagnostics: log export/share, local crash banner with GitHub issue link | 9.5 | `log_screen.dart`, `app_crash_banner.dart` |
| M4.9 | About: version, privacy statement, open-source licences (incl. Mornye) | 9.6 | `about_page.dart`, `assets/licenses` |
| M4.10 | Support Kalao row → `https://ko-fi.com/brinsley` (donate page reduced to one link) | 9.7 | `donate_page.dart` |
| M4.11 | Update check + user-started APK download, SHA-256 verify, installer hand-off | 9.8 | `update_checker.dart`, `apk_downloader.dart`, `update_dialog.dart` |
| M4.12 | Share-intent handling for `.kalaobackup`, `.lrc`, audio files | 7.3, 1.7 | `share_intent_service.dart` |

**Exit:** a backup made on one device restores on another (both modes) with no secrets inside; scheduled backup runs when due; the update flow installs a newer test release.

## M5 Extensions

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M5.1 | `crates/extensions` copied (runtime, host, manifest, package, repository, storage, manager, network_host, crypto, redact, logging, lyrics/metadata/health backends); Kalao capabilities; limits per EXTENSIONS.md §5 | 5.1 | `crates/extensions` |
| M5.2 | Install from file and repository; signature + SHA-256 checks; update checks; install prompt (hosts, permissions, fingerprint) | 5.2 | `repository`, `repo_provider.dart`, `repo_tab.dart` |
| M5.3 | Manifest-generated settings UI and button actions | 5.3 | `extension_detail_page*.dart`, `extension_action_forms.dart` |
| M5.4 | Allowlist enforcement, login callbacks (`kalao://ext/<id>/callback`), health checks, enable/disable, priority ordering | 5.4 | `extension_auth_launcher.dart`, `ExtensionAuthCallbacks.kt`, `extension_health.dart`, `extension_provider_priority.dart` |
| M5.5 | `kalao-ext` CLI (validate, test with fixtures, pack, sign); public sample extension **LRCLIB** (open API) in `examples/extensions/lrclib/`; EXTENSIONS.md published | 5.5 | Mornye `core/lyrics/lrclib.rs` as reference |
| M5.6 | Lyric fetch: parallel query, ranking, provider picker, priority page | 2.11 | `lyrics_provider_picker.dart`, `lyrics_provider_priority_page.dart`, `core::lyrics::matching` |
| M5.7 | Language detection drives annotation layers | 2.10 | `lyrics_language_guess.dart` |
| M5.8 | Metadata and artwork search/merge; song detail screen | 6.4 | `metadata_provider_priority_page.dart`, `track_metadata_*` |
| M5.9 | Search across library + metadata extensions | 6.2 (extensions) | `home_tab_search_results.dart` |
| M5.10 | Streaming playback with range requests and cache | 1.8 | `network_playback_cache.dart` |
| M5.11 | Offline downloads of tracks, stems, lyrics and annotations | 6.6 | §10 |
| M5.12 | Owner's private extensions packaged in the private repo and installed from a signed repository | 2.11 | private repo |

**Exit:** private lyrics and metadata extensions install from a signed repo and work; LRCLIB sample and EXTENSIONS.md are public; streaming and offline downloads work.

## M6 Stems and translation

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M6.1 | Copy `core::progress` (download progress); `crates/stems`: model manager (built-in catalogue, install with resumable download from GitHub Releases assets and SHA-256 check, delete, list with sizes), ONNX Runtime via `ort` + `onnxruntime-android`, XNNPACK/CPU (QNN optional), chunked inference with overlap-add, checkpoints, FLAC output | 4.1, 4.2 | STEM_SEPARATION §1 |
| M6.2 | Benchmark and choose Fast, Balanced and Quality models on 3 reference devices; confirm licences | 4.2 | — |
| M6.3 | Stem job service: `BackgroundWorkService` kind `stems`, progress notification with cancel, resume after process death, battery/thermal pause, queue | 4.1 | `BackgroundWorkService.kt` |
| M6.4 | Stems UI: per-song "Separate", Models screen (install, delete, default model; STEM_SEPARATION §1.2), per-song model override, job list, storage usage (Mornye cache management page) | 4.1, 4.2 | `cache_management_page.dart` |
| M6.5 | Remote client: key field, Test key, salted install hash, upload/progress/download, checksum, fallback on any failure | 4.3, 4.4 | STEM_SEPARATION §2 |
| M6.6 | `stem-server/`: gateway (axum, sqlx, Redis, limits), Python Demucs worker, `stem-admin` CLI, Prometheus metrics, `compose.yaml`, retention sweeper | 4.3 | — |
| M6.7 | `crates/providers` MyMemory client; `lyrics_translation.dart` adapted; quota handling; optional contact email; language table | 2.12 | `lyrics_translation*.dart` |
| M6.8 | UI languages ko, es, fr | 9.1 (next set) | `lib/l10n` |

**Exit:** on-device separation meets the targets in STEM_SEPARATION §1; a remote key binds to one device and falls back cleanly; translation stays within MyMemory's daily quota and degrades gracefully.

## M7 Scoring

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M7.1 | Melody extraction (pYIN on vocal stem) and cache | 3.3 | §9 |
| M7.2 | AAudio input, YIN live pitch, latency measurement per route | 3.3 | §9 |
| M7.3 | Scoring algorithm, per-line and total score, history rows | 3.3 | §9 |
| M7.4 | `pitch_lane.dart` (reference notes + live trace), score summary sheet | 3.3 | — |
| M7.5 | Monitoring with gain and reverb on wired/USB routes; Bluetooth warning | 3.4 | `audio_route_info.dart` |

**Exit:** real-time pitch lane and score; measured monitoring latency documented per reference device.

## M8 Parties

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M8.1 | `crates/party` from Mornye `link` (server, tls, pairing, ws, mdns, store) with the party protocol | 8.1, 8.3 | `crates/link` |
| M8.2 | Host UI: start party, QR card, guest approval, kick | 8.1 | `services/link/*` patterns |
| M8.3 | Guest UI: scan QR (`mobile_scanner`) or discover (`bonsoir`) + PIN, browse host library, queue songs | 8.1, 8.2 | — |
| M8.4 | Queue sync, host reorder/approve, mirrored lyrics and scoreboard on guests | 8.2, 8.4 | — |
| M8.5 | Recording a performance (local FLAC, share) | 3.5 | §9 |
| M8.6 | TV lyrics view over LAN HTTP | 8.5 | §13 |
| M8.7 | Start `desktop/`: copy `crates/desktop` (C ABI), `RustFfiBackend`, extract shared Dart package; then `web/` design | — | `crates/desktop`, `rust_ffi_backend.dart` |

**Exit:** a 5-guest party over LAN with queueing, mirrored lyrics and scores; TV view works in a desktop browser.

## Coverage

| Feature | M | Feature | M | Feature | M |
| --- | --- | --- | --- | --- | --- |
| 1.1 | M1.1–M1.3 | 2.10 | M5.7 | 6.1 | M1.7–M1.8 |
| 1.2 | M1.1, M1.13 | 2.11 | M5.6, M5.12 | 6.2 | M1.9, M5.9 |
| 1.3 | M1.1, M1.13 | 2.12 | M6.7 | 6.3 | M4.1 |
| 1.4 | M3.1 | 2.13 | M2.3 | 6.4 | M5.8 |
| 1.5 | M1.4 | 3.1 | M3.2 | 6.5 | M3.4 |
| 1.6 | M1.6 | 3.2 | M3.3 | 6.6 | M5.11 |
| 1.7 | M1.5 | 3.3 | M7.1–M7.4 | 6.7 | M4.2 |
| 1.8 | M5.10 | 3.4 | M7.5 | 7.1–7.6 | M4.3–M4.7 |
| 2.1 | M1.10, M1.13 | 3.5 | M8.5 | 8.1–8.4 | M8.1–M8.4 |
| 2.2 | M1.11 | 4.1 | M6.1, M6.3, M6.4 | 8.5 | M8.6 |
| 2.3 | M1.12 | 4.2 | M6.1, M6.2 | 9.1 | M1.14, M6.8 |
| 2.4 | M3.6 | 4.3 | M6.5, M6.6 | 9.2 | M1.14 |
| 2.5 | M3.7 | 4.4 | M6.5 | 9.3 | M3.5 |
| 2.6 | M2.1, M2.5, M2.6 | 5.1 | M5.1 | 9.4 | M1.15 |
| 2.7 | M1.13 | 5.2 | M5.2 | 9.5 | M4.8 |
| 2.8 | M2.2 | 5.3 | M5.3 | 9.6 | M4.9 |
| 2.9 | M2.4 | 5.4 | M5.4 | 9.7 | M4.10 |
| — | — | 5.5 | M5.5 | 9.8 | M4.11 |

**Distribution:** GitHub Releases only, from M3 (v0.1.0). Each release: per-ABI and universal signed APKs, SHA-256 checksums, changelog. No store builds.
