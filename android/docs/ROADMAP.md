# Roadmap

Milestones are ordered by dependency; each ends with a tested build on `main` and a tag. Feature numbers refer to FEATURES.md; "Mornye" names the source to copy or adapt (MORNYE_REUSE.md); design details are in IMPLEMENTATION.md (§ numbers below). Every feature in FEATURES.md appears in exactly one milestone; the coverage table at the end checks that.

## M0 Foundations — implemented (2026-11-15)

Status: ✅ built and tested; CI green.

| # | Task | Status | Mornye source |
| --- | --- | --- | --- |
| M0.1 | Root tooling: `.editorconfig`, `.gitattributes`, `cliff.toml`, `renovate.json` (automerge off), `NOTICE` (Kalao + Mornye attribution), `CONTRIBUTING.md`, issue templates (bug, lyrics, feature), PR template, `FUNDING.yml` (`ko_fi: brinsley`) | ✅ | root files |
| M0.2 | `rust_backend/` workspace: `Cargo.toml` (members `core`, `network`, `mobile`, `bindgen`), `rust-toolchain.toml`, workspace lints, `README.md` crate map, `Cargo.lock` seeded from Mornye's; licence `GPL-3.0-only` | ✅ (`providers` comes with M6.7) | `rust_backend/*` |
| M0.3 | `crates/network` and `crates/bindgen` copied and renamed | ✅ | `crates/network`, `crates/bindgen` |
| M0.4 | `crates/core`: JSON helpers, text, XML depth check, matching, cancellation (domains `DataJob`, `ExtensionRequest`), lyrics (`lrc`, `matching`, `errors`, `json`, `payloads` incl. TTML) with Mornye's tests and fixture; built-in provider config, LRCLIB, provider schemas and Paxsenix credits removed | ✅ (`progress` comes with M6.1) | `crates/core` |
| M0.5 | `crates/mobile`: UniFFI scaffolding; `invoke_application(method, args_json)` with a sorted method table (`initBackend`, `getBackendInfo`, `getLogs`, `clearLogs`, `setLoggingEnabled`); `run_native_data_job` (`hash_file`); cancellation registry; process-wide log buffer; `uniffi.toml` (`com.brinsley.kalao.backend`, `kalao_mobile`) | ✅ | `crates/mobile` |
| M0.6 | `scripts/build_rust_backend.sh` (host + android; arm64, armv7, x86_64; Linux, macOS and Windows hosts), `check_rust_backend.sh`, `build_android.sh`, `check_backend_apk.py` (ELF, ABI set, 16 KB `PT_LOAD` alignment) + `test_check_backend_apk.py` | ✅ | `scripts/` |
| M0.7 | Flutter project `android/` (`com.brinsley.kalao`, Flutter 3.47.8 via `.fvmrc`), `pubspec.yaml` (M0 subset), Mornye's `analysis_options.yaml` and `l10n.yaml` | ✅ | `pubspec.yaml`, `lib/` layout |
| M0.8 | Kotlin host: `KalaoApplication`, `MainActivity` routing (`nativeBackendMethods` + `MainActivityRoutingTest`), `MainActivityCalls.kt` (screen awake, background work, crash report), `SelectedCoreBackend.kt` (CoreBackend over UniFFI/JNA, JSON argument conversion), `NativeDataJobs.kt`, `__json_file` spill + stale-file sweep, `BackgroundWorkService` + `ForegroundWorkLock` + `CoalescingWorkRefresh` + `ForegroundServiceStartPolicy`, `AppCrashReporter`; Gradle `buildRustBackend` before `preBuild`, JNA, ProGuard rules, ABI splits, signing from `key.properties`; adaptive launcher icon; HTTPS-only network config; Android backup disabled | ✅ | `android/app/*` |
| M0.9 | Dart backend layer: `services/backend/{backend_channel,method_channel_backend}.dart`, `platform_bridge.dart` (typed calls, isolate JSON decode, `__json_file` spill) | ✅ (`RustFfiBackend` comes with `desktop/`) | `lib/services/backend`, `platform_bridge.dart` |
| M0.10 | App shell: `main.dart` (error handlers, settings, engine check), `app.dart` (go_router, `initialLocationForAppState`), `main_shell.dart` (Home, Library, Queue, Extensions placeholders + Settings), `setup_screen.dart` (language, theme) | ✅ (permission steps come with the features that need them) | `app.dart`, `screens/main_shell.dart`, `setup_*` |
| M0.11 | Theme layer: `app_tokens.dart`, `app_theme.dart` (Material 3; seed replaced by the brand palette in M1, BRANDING.md); widgets `settings_group`, `empty_state`, `app_crash_banner` | ✅ (further design-system widgets are copied when a screen needs them) | `lib/theme`, `widgets/` |
| M0.12 | l10n: `app_en.arb`, `app_zh.arb` (Simplified), `app_zh_Hant.arb`, `app_ja.arb`; `supported_locales.dart`; language picker | ✅ | `lib/l10n` |
| M0.13 | Settings: `models/settings.dart` (hand-written JSON, tolerant of unknown keys), `settings_provider` (shared_preferences), `settings_tab` (appearance, diagnostics, about with engine info and licences) | ✅ (models are hand-written; `secure_storage_options` comes with its first user in M5) | settings files |
| M0.14 | Logging and crash capture: `AppLogger` + `LogBuffer` with Mornye's redaction rules (plus MyMemory's `de=`), Rust log buffer merged in `log_screen` (copy, clear), `app_crash_service` + `AppCrashReporter.kt` (Dart errors saved as context only; banner after a real crash) | ✅ | logging files |
| M0.15 | CI `ci.yml`: gitleaks; fail if `*.kalaoext`, `android/extensions/` or `poc-webapp/` is tracked; Dart format + analyze + test; `check_rust_backend.sh` + script tests; Android `assembleDebug` + `testDebugUnitTest`, release APK build + audit + `apksigner`/`zipalign` checks | ✅ | `.github/workflows/ci.yml` |
| M0.16 | `release.yml`: tag `vX.Y.Z` (checked against pubspec) → arm64, arm32, x86_64 and universal APKs, V1–V4 signing and verification, payload audit, symbols artifact, GitHub Release with `SHA256SUMS.txt` and `git-cliff` changelog | ✅ (signs with the `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEYSTORE_PASSWORD` secrets) | `.github/workflows/release.yml` |

Tests added: Rust `backend` (method table sorted and dispatched, init, errors), `data_jobs`, `logging`; Kotlin `MainActivityRoutingTest`; Dart `platform_bridge_test` (decode, spill, errors), `settings_test`, `logger_test` (redaction, ring), `app_test` (setup → shell, engine info, logs, crash banner, locale).

**Exit:** `getBackendInfo` round-trips Dart → Kotlin → Rust on an emulator and a device; logs from Rust appear in the log screen; CI is green; `release.yml` produces signed APKs.

## M1 Local player — implemented (2026-11-15)

Status: ✅ built and tested locally (Rust: fmt, clippy, all workspace tests incl. 12 engine tests on rendered buffers and the POC fixtures; `libkalao_mobile.so` cross-compiles for arm64; Flutter analyze clean, 34 Dart tests); ⏳ the on-device exit checks (headset buttons, backgrounding, real decoding on AAudio) need an emulator or device run.

| # | Task | Features | Status | Source / § |
| --- | --- | --- | --- | --- |
| M1.1 | `crates/audio` (`kalao-audio`): Symphonia decoders, rubato (`FastFixedIn`, cubic), `ringbuf` SPSC rings (≈0.5 s), one decoder thread per source, mixer with ramped gains (10 ms) and an equal-power original/instrumental crossfade (150 ms), soft limiter, seek with flush (worker + consumer locks), clock with output-latency correction from cpal timestamps, completion; cpal output thread with rebuild after device errors; `player_position_stream` (`MainActivityProgressStreams.kt`, polls `playerState`); `NativeCrashTrace` + startup capture of native tombstones (`AppCrashReporter.captureNativeExit`) | 1.1, 1.2, 1.3 | ✅ (`PerformanceMode::LowLatency` is not exposed by cpal 0.16: M7) | IMPLEMENTATION §2 |
| M1.2 | Player methods `playerLoad`, `playerPlay`, `playerPause`, `playerStop`, `playerSeek`, `playerSetVolume`, `playerSetStemGains`, `playerSwitchTrack`, `playerState` | 1.1–1.3 | ✅ (`playerPrefetch` is not built) | §1 |
| M1.3 | `KaraokeDeck` (engine commands + interpolated position) and `PlayerController` (load, play/pause/seek, switch, vocal blend, history rows, session restore for "Continue singing") | 1.1 | ✅ (Mornye's multi-deck `music_player_service.dart` is not copied: Kalao has one deck) | `karaoke_deck.dart`, `player_provider.dart` |
| M1.4 | Media session: `audio_service` 0.18.19 from pub.dev with `MainActivity : AudioServiceFragmentActivity` (cached engine), `KalaoAudioHandler` (notification, lock screen, artwork, headset buttons), `audio_session` focus (duck, pause, resume after transient loss) and becoming-noisy pause | 1.5 | ✅ (fork not needed, LIBRARIES §2) | `playback_handler.dart` |
| M1.5 | Import: `file_picker` → staging copy → `hash_file` → `media/<sha256>.<ext>` (once per hash) → `probeAudio` (Symphonia tags, cover, duration, codec) → `pairImportFiles` (`core::pairing`: name similarity, instrumental markers incl. 伴奏/カラオケ/off vocal, ±2 s) → pairing sheet (titles, instrumental, lyrics file, include) with duplicate detection by hash | 1.7 | ✅ (Mornye's `core::tags`/`cover`/`filename` and the `rustix` patch are not needed: see §3) | §3 |
| M1.6 | Symphonia codecs (MP3, AAC/M4A, ALAC, FLAC, Vorbis, WAV); FFmpegKit (`ffmpeg_kit_flutter_new_audio` 2.5.7) converts the rest to FLAC once at import | 1.6 | ✅ | `main.dart` `_convertWithFfmpeg` |
| M1.7 | `library_schema.dart` (`song`, `media_file`, `lyric_doc`, `lyric_annotation`, `song_search`; history `play`; app state `playback_session`, `recent_access`), `library_database.dart`, `history_database.dart`, `library_provider.dart` | 6.1 | ✅ (`melody` and `stem_job` arrive with their features) | `library_*` |
| M1.8 | Home: search, Continue singing, Recently played, Recently added; Library: list/grid, sort (added, title, artist), selection mode with delete (removes unused media files); mini player | 6.1 | ✅ | `home_tab.dart`, `library_screen.dart` |
| M1.9 | Search keys via `rebuildSearchKeys` (`core::search_keys`): normalised title/artist, toneless pinyin and initials, kana romaji; prefix-ranked substring search | 6.2 (local) | ✅ | `library_search.dart`, §3 |
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
| M2.1 | Timed model: line start/end, word timing (`LyricWord` with its range in the line text), voices (`v1`/`v2`, backing `bg`), line translation, `timed` flag, per-song offset; document JSON version 2; active line from the interpolated engine clock (`KaraokeDeck.position`, song time × tempo), swept characters per frame (`utils/lyrics_timeline.dart`) | 2.6 | ✅ (Kalao-sized `lyrics_timeline.dart`, not Mornye's; a Rust mirror is added when a Rust consumer needs it, M7/M8) | `models/lyrics.dart`, `utils/lyrics_timeline.dart` |
| M2.2 | `core::lyrics::doc`: LRC and enhanced LRC (word tags in both common styles, line ends, `v1:`/`v2:` voices, `[bg:…]` rows) import; TTML import through Mornye's Apple payload reader (word timing, duet sides, backing vocals, head translations); `exportLyrics(doc, format)` to LRC (line starts) and enhanced LRC (round-trips line and word timing, ends, sections, breaks, voices); `.ttml` in the import pickers and pairing | 2.8 | ✅ | §4 |
| M2.3 | Sweep over the active line: word by word with word timing, linear over the line duration otherwise (capped at 10 s); `SweepText` clips a highlight layer to the sung characters and repaints without rebuilding; works under ruby (pinyin) too; setting "Karaoke sweep" | 2.13 | ✅ (Mornye's `player_lyrics_word_sweep.dart` is not copied) | `ruby_lyric_line.dart` |
| M2.4 | Tap-to-time sync editor (`/player/sync`): line and word modes (words = one per CJK character, else per word), hold to stamp the end, 50/75/100% speed while timing (`playerSetTempo`), tap-latency setting (default 40 ms; output latency is already in the engine clock), nudge ±10/±50 ms, replay line, undo, save as a new `lyric_doc` version (`userEdited`, layers kept), export LRC/eLRC | 2.9 | ✅ (speeds keep the pitch since M3.1) | `lyrics_sync_editor_controller.dart`, `lyrics_sync_screen.dart`, §4 |
| M2.5 | Offset control in the lyrics options sheet (±5 s in 50 ms steps, reset), stored in the current lyric version; LRC `[offset:]` is read and written | 2.6 | ✅ | `lyrics_options_sheet.dart` |
| M2.6 | Timing accuracy (±30 ms): engine test on rendered click tracks (through the resampler, at tempo 1 and 0.5); Dart test of the deck's interpolation against a simulated 30 Hz engine; on-device `integration_test/lyrics_timing_test.dart` (click track + LRC on the real engine) | 2.6 | ✅ tests written and the host ones pass; ⏳ the device test has not been run | §17 |

Tests added: Rust `core::lyrics::doc` (eLRC styles, round trip, LRC export, TTML), `mobile` (`exportLyrics`), `kalao-audio` (tempo, click-track timing); Dart `lyrics_test` (model, sweep maths, word splitting, editor, timing model, import/offset/export, Now playing sweep and offset, sync editor flow).

**Exit:** LRC import auto-follows within ±30 ms; the editor produces enhanced LRC that round-trips.

## M3 Modes, first release — implemented except the release (2026-11-17)

Status: ✅ built and tested locally (Rust: fmt, clippy, all workspace tests incl. key, tempo and loop on rendered buffers; `libkalao_mobile.so` cross-compiles for the three ABIs; Flutter analyze clean, 56 Dart tests); ⏳ M3.9 (the `v0.1.0` tag) waits for the owner and the signing secrets; ⏳ the modes need a pass on a device (sound of the stretcher, the loop seam, gamepad keys).

| # | Task | Features | Status | Source / § |
| --- | --- | --- | --- | --- |
| M3.1 | Signalsmith Stretch (`signalsmith-stretch` 0.1.3) on the mix bus: `playerSetKey` ±6 semitones, `playerSetTempo` 50–150% at the same pitch, bypassed when both are neutral; the reported position allows for the stretcher's delay; key and speed steppers in the lyrics options sheet | 1.4 | ✅ (the build needs libclang and a C++ compiler, see DEV_SETUP) | §2 |
| M3.2 | Learn mode: loop the current line (`playerSetLoop`), A–B repeat (long-press two lines), slow-down presets 50/75/90/100%, line stepping for timed lyrics, translation under a line when the lyrics carry one | 3.1 | ✅ (long-press a line to repeat it, a second line for A–B; the seam crossfades into the decoded loop start, so it has no gap) | §5 |
| M3.3 | OG Karaoke mode: large two-line layout with the sweep, countdown dots before a line that follows a gap ≥ 4 s (intro included), screen kept on while playing, next singer from the queue after the last line | 3.2 | ✅ (Mornye's `lyric_gap_indicator.dart` and `lyrics_screen_awake.dart` are not copied: Kalao-sized versions) | `karaoke_lyrics_view.dart` |
| M3.4 | Queue: `queue_item` table (app state v2), add (Home long-press, Library selection, Now playing), reorder, remove, clear, singer name and mode per entry; the next entry starts when a song ends | 6.5 | ✅ | `library_queue_store.dart`, `queue_provider.dart`, `queue_tab.dart` |
| M3.5 | Keyboard and gamepad shortcuts (Space/A, ←/→ and L1/R1 5 s, ↑/↓ line, S/X switch track, L/Y loop, ? help) and the help sheet | 9.3 | ✅ | `shortcuts_sheet.dart` |
| M3.6 | `core::annotate::japanese` (lindera 6.2 with embedded IPADIC): furigana over kanji runs, romaji per word with spoken particles, romaji search keys for kanji titles; furigana above and romaji below the line, each with a toggle | 2.4 | ✅ (the embedded dictionary adds about 50 MB to `libkalao_mobile.so` per ABI) | §4 |
| M3.7 | `core::annotate::chinese_variant` (`ferrous-opencc` 0.4: s2t, s2tw, s2hk, t2s); the Chinese-characters setting converts lyrics for display through `convertChinese` | 2.5 | ✅ (the variant is applied when lyrics are shown, not stored as a layer, so changing the setting needs no regeneration) | §4 |
| M3.8 | Tutorial (after setup, four pages) and What's New (once per version after an update) screens with Kalao content | — | ✅ | `tutorial_screen.dart`, `whats_new_screen.dart` |
| M3.9 | **First GitHub Release** (`v0.1.0`) via `release.yml` | — | ⏳ needs a new tag: `v0.1.0-alpha` crashed on launch (`libc++abi` was not linked); the build now links it and fails on any unresolved symbol | `release.yml` |

Tests added: Rust `kalao-audio` (tempo keeps pitch, key keeps speed, loop wraps, click timing through the stretcher), `core::annotate::{japanese, chinese_variant}`, `mobile` (layers, `convertChinese`); Dart `modes_test` (karaoke frames, queue store, modes/key/tempo/loop/stepping, queue advance, Japanese layers and Chinese variant, Karaoke screen, queue tab, What's New and help).

**Exit:** Learn and OG Karaoke modes usable end to end in zh/ja/en songs; v0.1.0 APKs on GitHub Releases with checksums.

## M4 Library, backup, about — implemented (2026-11-18)

Status: ✅ built and tested locally (Rust: fmt, clippy, all workspace tests incl. the backup archive round trip and the unsafe-archive checks; Flutter analyze clean, 82 Dart tests; Kotlin `compileDebugKotlin` + `testDebugUnitTest`); ⏳ the on-device exit checks (a backup made on one device restored on another in both modes, a scheduled backup into a real SAF folder, the update flow installing a newer test release, opening files from a file manager) need devices and a published release.

| # | Task | Features | Status | Source / § |
| --- | --- | --- | --- | --- |
| M4.1 | Favorites (loved songs): `favorite` table (library v2), heart on Now playing, Library filter and selection action | 6.3 | ✅ | loved-tracks pattern |
| M4.2 | History rows (`play`) with mode and singer (score arrives with M7); stats screen (totals, last 7 days, most played, most practised, best scores) | 6.7 | ✅ (aggregated in SQLite; no `statsAggregate` job is needed) | `stats_screen.dart`, §7 |
| M4.3 | Backup export: `VACUUM INTO` snapshots, settings without device keys, covers, optional media; save to a SAF document; `native_backup` archive in the `backupWrite` data job | 7.1, 7.2 | ✅ | `backup_service.dart`, `native_backup.rs`, §12 |
| M4.4 | Restore: `backupInspect` (checked extraction) + preview, Merge and Replace in Dart over an attached copy, safety backup before Replace | 7.3 | ✅ (no database swap or `backupRestore` job: both modes run in one transaction per database) | `backup_screen.dart`, §12 |
| M4.5 | Scheduled backup (due-check on start/resume, keep last N, `backup_run` log, hourly retry after a failure) | 7.4 | ✅ | `backup_provider.dart` |
| M4.6 | Secrets excluded from backups | 7.5 | ✅ (backups never read secure storage; restored extensions ask for secrets in M5.3) | §12 |
| M4.7 | POC import: export script in the private POC (`poc-webapp/scripts/export-kalao.ts`) + `PocImportService` | 7.6 | ✅ (Dart, not a data job; attaches to already-imported songs by title and artist, as the POC's audio is not migrated) | §12 |
| M4.8 | Diagnostics: log export through the share sheet, crash banner with a pre-filled GitHub issue link | 9.5 | ✅ | `log_screen.dart`, `app_crash_banner.dart` |
| M4.9 | About: version, privacy statement, open-source licences (incl. the GPL-3.0 and Mornye's LGPL-3.0 texts) | 9.6 | ✅ | `privacy_screen.dart`, `assets/licenses` |
| M4.10 | Support Kalao row → `https://ko-fi.com/brinsley` | 9.7 | ✅ | `settings_tab.dart` |
| M4.11 | Update check + user-started APK download, SHA-256 verify, installer hand-off | 9.8 | ✅ (needs a published release to try end to end) | `update_service.dart`, `update_dialog.dart`, §14 |
| M4.12 | Opening and sharing `.kalaobackup`, `.lrc`/`.ttml`/`.txt` and audio files | 7.3, 1.7 | ✅ (native `SharedFiles.kt` instead of `receive_sharing_intent`; `.kalaoext` joins in M5) | `shared_files.dart` |

Tests added: Rust `native_backup` (round trip, newer format, damaged/unlisted/missing/unsafe entries, cancellation); Dart `stats_test` (favorites, library v1→v2, stats buckets, stats screen), `backup_test` (device keys, Replace to another device, Merge with human layers and play de-duplication, newer lyrics win, backup without media, newer schema refused), `backup_controller_test` (save to document, scheduled due check and pruning, failure retry, Backup screen save and restore), `shared_files_test`, `update_test` (versions, ABI asset, check, verified download, daily check, install), `poc_import_test`.

**Exit:** a backup made on one device restores on another (both modes) with no secrets inside; scheduled backup runs when due; the update flow installs a newer test release.

## M5 Extensions

| # | Task | Features | Source / § |
| --- | --- | --- | --- |
| M5.1 | `crates/extensions` copied (runtime, host, manifest, package, repository, storage, manager, network_host, crypto, redact, logging, lyrics/metadata/health backends); Kalao capabilities; limits per EXTENSIONS.md §5 | 5.1 | `crates/extensions` |
| M5.2 | Install from file and repository; signature + SHA-256 checks; update checks; install prompt (hosts, permissions, fingerprint) | 5.2 | `repository`, `repo_provider.dart`, `repo_tab.dart` |
| M5.3 | Manifest-generated settings UI and button actions; restored extensions ask for their secrets again (from M4.6) | 5.3, 7.5 | `extension_detail_page*.dart`, `extension_action_forms.dart` |
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
---

# TL;DR version that's more readable - (just a summary of above)

## **M0 — Foundations**

Implemented

**In simple terms: Build the basic app and its technical infrastructure.**

This milestone creates the foundations that everything else will run on.

What it achieves:

- Creates the Android app and its basic screens.
- Establishes the connection between Flutter (the app interface) and Rust (the audio and processing engine).
- Creates the settings, language selection and appearance options.
- Sets up error reporting, logging and crash detection.
- Establishes automated testing and the process for building and releasing the app.
- Prepares the app to support different Android devices.

**What the user gets:** A functioning app shell with settings, navigation and the underlying technology ready for the music features.

Think of this as building the house's foundations, plumbing and electrical systems before installing the furniture.

## **M1 — Local player**

Implemented

**In simple terms: Make Kalao a working karaoke music player.**

This is where the app becomes useful for actually playing music.

What it achieves:

- Imports songs from the device.
- Recognises original and instrumental versions of the same song and pairs them together.
- Supports common audio formats such as MP3, FLAC, WAV and AAC.
- Plays music with the ability to pause, resume, seek and adjust volume.
- Switches between original vocals and instrumental versions without restarting the song.
- Allows the user to blend the original vocals with the instrumental track.
- Imports lyrics from text files, LRC files or embedded song information.
- Displays lyrics while the song plays.
- Adds Chinese pinyin above the lyrics.
- Provides song search, library management and recently played songs.
- Supports background playback, lock-screen controls and headset buttons.

**What the user gets:** A working local karaoke player with a music library, lyrics, instrumental switching and Chinese pinyin support.

This is the milestone that delivers the core reason for using Kalao.

## **M2 — Timed lyrics**

Implemented

**In simple terms: Make the lyrics follow the music accurately, including individual words.**

M1 can display lyrics, but M2 makes them synchronise with the actual singing.

What it achieves:

- Supports lyrics with individual line start and end times.
- Supports word-by-word timing.
- Highlights the lyrics progressively as the singer sings.
- Supports multiple singers (duets), backing vocals and translations.
- Imports and exports enhanced LRC and TTML lyric formats.
- Provides an editor where users tap along with the music to create lyric timings.
- Allows users to adjust lyrics when they are slightly early or late.
- Saves edited lyrics as new versions without losing the original.
- Supports a karaoke-style highlighting animation, including pinyin.

**What the user gets:** Proper synchronised karaoke lyrics, where the words light up as they are sung, rather than simply displaying a block of text.

An important addition is the timing editor: users can create or correct synchronised lyrics themselves instead of relying on existing lyric files.

## **M3 — Modes and first release**

Implemented; the first release is pending.

**In simple terms: Turn the player into a complete karaoke and singing-practice experience.**

This milestone adds different ways to use Kalao, depending on whether someone wants to practise or sing for fun.

What it achieves:

- **Pitch adjustment:** Change a song's musical key without changing its speed.
- **Tempo adjustment:** Slow down or speed up a song without changing its pitch.
- **Learn mode:** Repeat individual lyric lines or selected sections of a song. Useful for practising difficult parts.
- **OG Karaoke mode:** A dedicated karaoke screen with large lyrics, animated highlighting and countdown indicators before singing begins.
- **Song queue:** Build a playlist, rearrange songs and assign singers and modes to individual songs.
- **Keyboard and gamepad support:** Control playback and karaoke features using physical buttons.
- **Japanese lyrics support:** Automatically display furigana (readings above kanji) and romaji.
- **Chinese character conversion:** Switch between Simplified and Traditional Chinese lyrics.
- **Tutorial:** Introduces new users to the app.
- **What's New:** Explains new features after updates.

**What the user gets:** Two distinct experiences:

1. A practice environment for learning songs, adjusting pitch and speed, and repeating difficult sections.
2. A proper karaoke environment for singing along with large, synchronised lyrics.

## **M4 — Library, backup and about**

Implemented; the on-device checks are still to do.

**In simple terms: Make the app's music library safer, easier to manage and maintain.**

This milestone focuses on protecting users' music collections and making the app easier to maintain.

What it achieves:

- Mark songs as favourites.
- Keep a detailed history of songs played, including singer, mode and score.
- View personal singing and listening statistics.
- Back up the music library, lyrics, settings and optionally audio files.
- Restore a backup on another device.
- Choose whether to merge a backup with existing content or replace it.
- Automatically create scheduled backups.
- Keep passwords and private access keys out of backups.
- Import data from an earlier proof-of-concept version of Kalao.
- Export diagnostic logs to help report problems.
- Provide an About page with version, privacy information and licences.
- Check for updates and download new APK versions directly.
- Open shared audio and lyrics files directly in Kalao.

**What the user gets:** Peace of mind that their music library, lyrics and settings can be backed up and recovered if they change phones or lose data.

## **M5 — Extensions**

Planned

**In simple terms: Allow Kalao to gain new features through installable add-ons.**

This is a major step towards making Kalao expandable rather than having every feature built directly into the main app.

What it achieves:

- Allows users to install extensions from files or repositories.
- Checks extension signatures to make sure they are genuine.
- Allows extensions to have their own settings and actions.
- Provides permission controls for extensions.
- Allows extensions to be updated, enabled or disabled.
- Provides tools for developers to create their own extensions.
- Fetches lyrics from online providers.
- Searches for song information and album artwork.
- Adds streaming playback with caching.
- Allows users to download songs, lyrics and other content for offline use.

**What the user gets:** An app that can be customised and expanded. For example, users could install different online lyric providers rather than being restricted to one built-in service.

This also introduces the possibility of streaming music rather than relying entirely on locally stored files.

## **M6 — Stems and translation**

Planned

**In simple terms: Separate songs into individual audio components and translate lyrics.**

This milestone introduces one of the more powerful features of Kalao.

What it achieves:

- Separates a song into different audio components (called stems).
- Allows users to isolate vocals, instruments and other parts of a song.
- Provides different separation quality and speed options.
- Allows separation to happen in the background.
- Supports remote audio separation when local processing isn't suitable.
- Adds automatic lyric translation.
- Adds Korean, Spanish and French as app interface languages.

**What the user gets:** The ability to turn an ordinary music file into something much more flexible.

For example, a user could:

- Remove the original singer's voice to create an instrumental.
- Isolate the vocals to study the singer's technique.
- Separate instruments for practice.
- Translate lyrics into another language to understand their meaning.

An important distinction: M1 switches between two existing audio files (original and instrumental). M6 aims to create those separate audio components from a single recording.

## **M7 — Scoring**

Planned

**In simple terms: Let users measure how accurately they sing.**

This milestone introduces singing assessment.

What it achieves:

- Analyses the melody of the original song.
- Listens to the user's voice through the microphone.
- Detects the pitch of the user's singing in real time.
- Compares the user's pitch against the original melody.
- Calculates scores for individual lines and the overall performance.
- Displays a visual guide showing the correct notes and the user's actual pitch.
- Provides monitoring with gain and reverb options.

**What the user gets:** A karaoke scoring system that shows whether they're singing the right notes.

Think of the scoring systems found in games such as SingStar: the app listens to your voice and measures how closely you follow the melody.

## **M8 — Parties**

Planned

**In simple terms: Turn Kalao into a multiplayer karaoke experience.**

This milestone expands Kalao beyond a single person's device.

What it achieves:

- Allows someone to host a karaoke party over a local network.
- Allows guests to join by scanning a QR code or entering a PIN.
- Lets guests browse the host's music library.
- Allows guests to add songs to a shared queue.
- Allows the host to approve songs and manage the queue.
- Synchronises lyrics and scores across connected devices.
- Allows users to record their performances.
- Adds a lyrics display that can be shown on a television.
- Begins development of desktop and web versions.

**What the user gets:** A shared karaoke experience where multiple people can join, choose songs, take turns singing and follow the lyrics on their own devices or a TV.

The roadmap's exit target is a party with up to five guests connected over a local network.

# **The bigger picture**

Here's how the milestones fit together as a product development journey:

## **Kalao's evolution**

1. **M0 — Build the foundation**

   Get the app running and establish its technical infrastructure.
2. **M1 — Play music**

   Import songs, play them and display lyrics.
3. **M2 — Synchronise lyrics**

   Make lyrics follow the singer, word by word.
4. **M3 — Sing and practise**

   Add karaoke mode, practice tools, pitch and tempo controls.
5. **M4 — Protect the library**

   Add favourites, statistics, backups and updates.
6. **M5 — Expand functionality**

   Introduce extensions, online lyrics and streaming.
7. **M6 — Enhance the music**

   Separate vocals and instruments, and translate lyrics.
8. **M7 — Measure performance**

   Introduce real-time singing analysis and scoring.
9. **M8 — Sing together**

   Add multiplayer karaoke, shared queues and TV support.

## **My interpretation of the roadmap**

There are three particularly important stages in Kalao's development:

1. **M0–M3: Establish the core product.** These milestones turn Kalao into a usable karaoke and singing-practice application.
2. **M4–M6: Make it a platform.** Backups, extensions, online services, audio separation and translation make it considerably more powerful.
3. **M7–M8: Make it an experience.** Scoring and multiplayer transform Kalao from a personal music tool into something closer to a karaoke game and social platform.
