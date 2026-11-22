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
Mornye's large player and library files (`music_player_service.dart` 2,800 lines, `home_tab*` 7,000, `library_database.dart`, `player_lyrics.dart`, `listening_statistics.dart`, `backup_service.dart`, `update_checker.dart` + `apk_downloader.dart`, `share_intent_service.dart`) are written around Mornye's many decks, sources and download metadata. Kalao keeps their roles and implements smaller versions: `player_provider.dart`, `karaoke_deck.dart`, `playback_handler.dart`, `home_tab.dart`, `library_screen.dart`, `library_database.dart`, `library_queue_store.dart`, `now_playing_screen.dart`, `ruby_lyric_line.dart`, `karaoke_lyrics_view.dart`, `utils/lyrics_timeline.dart`, `stats_screen.dart` over `HistoryDatabase.stats`, the local library (`local_library_provider*.dart`, `local_library_scan_prefs.dart`) as `library_folder_service.dart` + `library_folder_store.dart` + `library_folder_provider.dart` + `settings/library_folders_screen.dart` (folders in the library database instead of preferences, Kalao's pairing per directory, no tag or cover cache, no network sources), `backup_service.dart`, `update_service.dart`, `screens/shared_files.dart` + `SharedFiles.kt`. The `audio_service` and `ffmpeg_kit_flutter_new_audio` forks are replaced by the published packages because their patches cover Android Auto, browsing, notification custom actions and Windows only.

### Planned, by milestone
- **M5 extensions (done):** copied `services/lyrics_language_guess.dart` and `services/secure_storage_options.dart`; written Kalao-sized: `models/extension.dart`, `services/extension_service.dart`, `providers/extension_provider.dart`, `screens/extensions/*` (tab, detail with the manifest settings form, install prompt, repositories, one priority screen for all capabilities instead of Mornye's per-capability pages), `widgets/{extension_widgets,lyrics_provider_picker}.dart`, `screens/song_detail_screen.dart`. Mornye's cover cache is not used: chosen artwork is saved into `covers/`.
- **M6 translation and stems:** `services/{lyrics_translation,lyrics_translation_alignment,lyrics_translation_languages}.dart` with a `MyMemoryClient` call through `PlatformBridge` instead of `LyricsAiClient` (keep distinct-line batching, hashing, caching, alignment); `providers/lyrics_translation_provider.dart`; `screens/settings/cache_management_page.dart`; `services/connectivity_monitor.dart`.
- **M5B Local Library (done):** the rest of Mornye's Local Library, §7.
- **M7 scoring:** `services/audio_route_info.dart`.
- **M8 parties:** Dart `services/link/*` → `services/party/*` (host, guest client, discovery with `bonsoir`).
- **Design system, when a screen needs it:** Mornye's `app_*` and `expressive_*` widgets, `theme/{app_motion,material_expressive,material_symbols}.dart`, `utils/settings_search_catalog.dart`.

### Not used
Downloads (all `download_*`, `native_download_*`, `DownloadService*.kt`), FFmpeg re-enrich/ReplayGain/Hi-Res, network storage (SMB, WebDAV, Subsonic), Mornye Link library sync, AutoMix and autoplay, equalizer, Discord presence, Last.fm, concerts, weekly releases, listening rewind, music recognition, motion artwork, cast, USB bit-perfect output, Android Auto browsing, iOS, the Mornye glass visual style (`liquid_glass_easy`, `mornye_*` widgets), `user_profile_store` and `profile_settings_page` (no accounts), `app_remote_config_service`, the multi-deck player (`playback_deck`, `music_player_service`, `playable_media`, `content_uri_playback_cache`, `media_session_art_cache`).

## 5. Android host (Kotlin)

Copied and trimmed: `MainActivity.kt` (routing skeleton), `MainActivityCalls.kt` (Mornye's lifecycle and service calls in one file), `MainActivityProgressStreams.kt`, `BackgroundWorkService.kt`, `ForegroundServiceStartPolicy.kt`, `ForegroundWorkLock.kt`, `CoalescingWorkRefresh.kt`, `AppCrashReporter.kt`, `NativeCrashTrace.kt`, `MornyeApplication.kt` → `KalaoApplication.kt`, `src/rust/kotlin/{SelectedCoreBackend,NativeDataJobs}.kt`, `src/test/kotlin/MainActivityRoutingTest.kt`, `proguard-rules.pro` (JNA keep rules), `build.gradle.kts` (Rust task, ABI splits, signing config). Kalao's own: `MainActivityStorageCalls.kt` (SAF for backups, instead of Mornye's `MainActivitySaf*` and `SafDocument*` files), `MainActivityLibraryFolderCalls.kt` (music folders: the tree walk and descriptor reads of Mornye's `MainActivitySafScan.kt` and `MainActivityLibraryScanCalls.kt`, without checkpoints, CUE sheets, pause or a Rust-side scanner), `MainActivityUpdateCalls.kt`, `SharedFiles.kt`.

Kalao's `ExtensionAuthCallbacks.kt` (M5) takes login redirects (`.kalaoext` files arrive through `SharedFiles.kt`, so `MainActivityExtensionIntents.kt` is not needed). Planned: `AudioRouteInfo.kt` (M7).

Not used: `DownloadService*`, `NativeFinalizer*`, `NativeFlac*`, `HiResPlayback`, `UsbBitPerfect*`, `UsbDirectPlayback`, `Dsd*`, `BitPerfectPcm`, `CastOutputPlugin`, `MornyeCast*`, `PlayerWidget*`, `DownloadQueueWidgetProvider`, `LinkConnectionService`, `LocalNetworkPlugin` (replaced by party calls), `MusicHapticsPlugin`, `NativeAudio` (replaced by Rust audio), `AudioOpenBridge`, `SharedEngineChannels`.

## 6. Dependencies

Kalao keeps Mornye's pinned versions for every dependency it shares (LIBRARIES.md), so known-good combinations (e.g. `flutter_secure_storage 10.3.4` migration constraints, `rquickjs 0.14.0`, the `rustix` patch) carry over. Renovate is configured as in Mornye.

## 7. Local Library (music folders)

Mornye's **Local Library** indexes music folders the user already has, in place. Kalao calls it **music folders** (FEATURES.md 6.8). The core was built Kalao-sized in M4.13 (IMPLEMENTATION.md §3); the rest of Mornye's feature, adapted for karaoke, was built in milestone **M5B** (ROADMAP.md). This section records what Mornye's feature does (surveyed at Mornye `c4a1c7b`, 2026-11-19) and, per part, whether Kalao **built** it or **cut** it.

### 7.1 What Mornye's Local Library does

**Sources.** Settings → Local Library → Add library folder, any number of them. On Android each is a SAF tree with a persisted grant (internal storage, SD card, USB drive); iOS uses security-scoped bookmarks, desktop plain paths, and network shares (`network://`: SMB, WebDAV, Subsonic) are sources too. A source row (`library_sources`) has a display name, removable flag, enabled switch, online/offline state, last scan time and last scan error. An offline source keeps its tracks, shown as unavailable, and is rescanned when it reconnects. Removing a source removes its indexed tracks, never the files.

**Scan.** One scan at a time, source by source:

1. *Full or incremental.* The first scan, or **Force Full Scan**, reads every file. Later scans compare a snapshot of indexed paths, modification times and `audio_metadata_scan_version` with the listing; only new, changed or older-version files are read, and files no longer listed leave the index. Raising the scan version re-reads old rows once.
2. *Listing.* Kotlin lists SAF trees (`SafTreeListing.kt`, batched `DocumentsContract` queries), skipping `.partial` files and extensions outside `flac m4a mp4 aac mp3 opus ogg ape wv mpc wav aiff aif dsf dff cue`. Desktop walks folders in Rust (`extensions/backend/library/scan.rs`).
3. *Reading.* Rust's own tag reader (`core::tags`: ID3v2/v1, MP4 atoms, Vorbis comments, APE, FLAC) reads each file through a descriptor Kotlin lends (`/proc/self/fd/N`). The descriptor is **duplicated, never reopened**, because Android's AppFuse proxies reject a reopen. Reads run in a bounded pool that keeps result order. A row holds title, artist, album, album artist, track and disc numbers and totals, duration, release date, genre, composer, label, copyright, ISRC, explicit, bit depth, sample rate, bitrate, format, embedded-lyrics and ReplayGain flags, and modification time. A tagless file falls back to its file name.
4. *Covers.* Embedded art is saved once as a thumbnail (`library_covers/`). A song without embedded art uses its folder's image (`cover`, `folder`, `front`… by priority, case-insensitive, AppleDouble files skipped; disc subfolders use their parent's), and every song in that folder shares one thumbnail. Unreferenced thumbnails are pruned.
5. *CUE sheets* split one audio file into virtual tracks, and a split service publishes the outputs.
6. *Ingestion.* Rows are staged and swapped into the live `local_library.db` by Rust (`mobile/src/native_library.rs`, 300 rows per batch, one swap transaction; a corrupt row is skipped and reported).
7. *Control.* Progress (percent, files, current file) feeds a foreground-service notification. A scan can be **paused**, **resumed** or **cancelled**. After process death, the next start recovers the scan (an active-scan marker in preferences, checkpoints, `LibraryScanExitInfo.kt` reading `ApplicationExitInfo`). **Unreadable files** are kept per source (the first 100 with the reader's reason, plus a count).
8. *Auto scan:* off, every app open, daily or weekly.

**Index.** The `library` table holds one row per file (`file_path` unique, `source_id`), normalised names, `match_key`/`album_key`, sort columns, an FTS5 search table, ISRC and match-key reference counts (for "In Library" badges on download results), path keys, a file-size index, and a `library_visible` view that hides rows superseded by downloads or CUE splits. Dart owns the schema (`library_schema.dart`, v22).

**Browse.** The Library tab merges downloads and scanned files (`UnifiedLibraryItem`) into Playlists, Artists, Albums, Songs, Genres, Folders, Recently added and Downloads:
- *Album pages:* disc and track order, play, shuffle, completeness ("3/12 tracks").
- *Artist pages:* Albums | Songs, keeping the last choice.
- *Genres:* multi-genre tags are split by a separator.
- *Folder tree* (`library_directory_view.dart`): counts, Play and Shuffle for everything under a folder, then its subfolders and songs.

Lists page through SQLite with keyset cursors (`library_browse_provider.dart`, `queue_library_pager.dart`) and share counts (`library_counts_provider.dart`). They have a fast scroller with a letter or month bubble, a list/grid toggle and a default-view setting.

**Filters and sorts.**
- *Filters:* source, quality (Hi-Res, CD, lossy), format, metadata (complete; missing year, genre, album artist, artist, track or disc number, ISRC, label, lyrics or ReplayGain; malformed ISRC) and incomplete albums.
- *Sorts:* latest, oldest, title, artist, album, year, genre, size.

**Search.** Every query word must match, in any field and any order. Punctuation only separates words and is never an SQL or FTS operator; results are ranked and bounded in SQLite (`library_search.dart`). A **Lyrics** filter searches lyrics embedded in the files, through a disposable cache that is built only while the filter is open.

**Actions.**
- *Selection bar:* play, shuffle, add to queue or playlist, like, delete files, re-enrich tags, convert, FLAC upgrade.
- *Settings:* **Cleanup Missing Files**, **Clear Library**, **Review duplicates**, **Find Moved Downloads**, **Re-enrich All Tracks** (writes tags), **Find Missing Artwork** (covers and animated covers from metadata extensions, kept in the app; covers the user removed are remembered and not put back), and a file reorganiser driven by a folder/filename template.
- *Home:* generated **Mixes** (genre, decade, artist).
- *Playback options:* built-in or external player, ReplayGain/R128 normalisation, what a tap on a song does.

### 7.2 Kalao's adaptation (principles)

- **One song table.** A folder file is a `song` row with a `media_file` (`source = folder`, `path` = the document URI). Lyrics, timing edits, annotations, favorites, plays and the queue hang off `song.id`, so Mornye's separate `library` table and `UnifiedLibraryItem` merge are not needed. *Built.*
- **Dart ingests; Rust never opens the live databases** (ADR-006). Kotlin lists the tree, Rust probes a file, and Dart decides and writes. Mornye's native ingestion exists for six-figure libraries over network shares. *Built.*
- **Kalao never changes folder files.** It does not copy, move, delete or retag them. Mornye's file-changing actions are cut. *Built.*
- **Karaoke pairing per directory.** An instrumental and a lyrics file join their original song (`core::pairing`), including when they appear in a later scan. *Built.*
- **User data survives moves and missing files.** A song whose original is gone (or whose folder is offline) becomes *unavailable* instead of leaving the library, with its lyrics, plays and favorites. A new file with the same `song_key` in any music folder is relinked to it, and **Clean up missing songs** deletes the missing ones after a confirmation that counts those with lyrics. *Built (M5B).*
- **Browse like Mornye, filter for karaoke.** Albums, Artists, Genres, Folders and paging come from Mornye. The filters ask karaoke questions (lyrics, timing, instrumental) instead of audiophile ones (bit depth, ReplayGain). *Built (M5B).*
- **Formats.** Formats Symphonia cannot decode are indexed through FFprobe and converted to FLAC on first play (§7.3). *Built (M5B).*

### 7.3 Feature verdicts

| Mornye feature | Kalao |
| --- | --- |
| Several SAF folders, remove (rows only, grant released), lost access shown, re-picking restores it | **Built** (M4.13; nested folders are refused) |
| Online/offline for removable storage, rescan on reconnect | **Built** (M5B): *offline* (volume not mounted) is told from *access lost*; an offline folder's songs stay, shown unavailable, and are back after the next scan (on resume) |
| Enable/disable a source without removing it | **Cut** (remove and re-add costs nothing: songs are relinked, §7.2) |
| Incremental scan by size + modification time; unchanged files not read | **Built** (`folder_file`) |
| Force Full Scan, scan-version re-read after a reader upgrade | **Built** (M5B, `folder_file.scan_version`) |
| Tags: title, artist, album, ISRC, embedded lyrics, duration, codec, cover | **Built** (Symphonia `probeAudio`) |
| Tags: album artist, track/disc number, date, genre, composer | **Built** (M5B): `probeAudio` reads Symphonia's standard tag keys. Mornye's `core::tags` is not copied: Symphonia already reads these, and undecodable formats get their tags from FFprobe (next row) |
| Formats Symphonia cannot decode (Opus, APE, WavPack, Musepack, DSF/DFF) | **Built** (M5B): indexed with FFprobeKit tags, converted once to FLAC with FFmpegKit on first play into `converted/` (newest 1 GiB kept) |
| Folder-image covers (stem priority, disc subfolders use their parent's, one shared image) | **Built** (M5B; Mornye's `cover/folder.rs` rule in `utils/folder_cover.dart`; the image is copied once into `covers/`) |
| Descriptor lending | **Built**: the lent descriptor is duplicated (`kalao-audio::open_file`) instead of reopened, as Mornye does, because AppFuse-proxied providers reject a reopen; Dart reads lyrics files and images through `copyDocumentToFile` (ADR-018) |
| Progress in the foreground work service, cancel, scan on start | **Built** |
| Pause/resume, checkpoints, interrupted-scan recovery, exit info | **Cut**: every finished file is committed, so an incremental rescan continues where a cancelled or killed scan stopped |
| Unreadable/skipped files list | **Built** |
| Auto scan: off, every app open, daily, weekly | **Built** (M5B; every app open, daily, weekly or manual, run when the app opens, as ADR-016) |
| Direct native ingestion, FTS5 table, lookup summary, path keys, file-size index, `library_visible` view | **Cut** (Dart ingests; `song_search`, `song_key` and `media_file.bytes` cover these) |
| Songs list: grid/list, sort (added, title, artist), favorites filter, selection | **Built** (M1.8, M4.1) |
| Albums, Artists, Genres, Folders, Recently added; album page (disc/track order, Sing all, Shuffle), artist page (Albums \| Songs), folder tree with counts and Sing all | **Built** (M5B, over every song, whatever its origin; Recently added is the Songs list's default sort) |
| Keyset paging, shared counts, fast scroller, last view remembered | **Built** (M5B) with offset pages of 100 instead of keyset cursors |
| Filters | **Built** (M5B), adapted: origin (imported, folder, extension), format, lyrics (none, plain, line-timed, word-timed), has instrumental, favorites, unavailable, missing artwork/genre/year |
| Sorts | **Built** (M5B): latest, oldest, title, artist, album, year, genre, size (no "most sung": plays live in the history database; Stats ranks them) |
| Quality filter, incomplete albums, ISRC/label/ReplayGain checks | **Cut** (collector features) |
| Every word in any field, any order | **Built** (M5B): Mornye's word rule over Kalao's `song_search` keys, so pinyin, initials and romaji still match |
| Lyrics search | **Built** (M5B), adapted (Home's "In lyrics" section): matches `lyric_doc` text in the database, with no audio reads or cache |
| "In Library" badge | **Built** (M5B): Home's extension results are marked by ISRC or `song_key` |
| Selection: play, shuffle, add to queue, favorite | **Built**: select all, queue, add to playlist, favorite, delete; *Sing all* and *Shuffle* are on the album, artist, genre, folder and playlist pages |
| Selection: delete files; re-enrich, convert, FLAC upgrade, reorganise, tag writing | **Cut** (Kalao never changes folder files) |
| Cleanup Missing Files | **Built** (M5B), with the unavailable state (§7.2) |
| Clear Library | **Cut** (removing a folder does it per folder) |
| Review duplicates | **Built** (M5B): copies of a song across folders, imports and downloads by `song_key` (no SHA-256 check); keeping one moves the others' lyrics, favorites, plays, queue and playlist entries to it |
| Find Missing Artwork | **Built** (M5B): artwork extensions, per album, saved in `covers/`, with results and removals remembered; animated covers cut |
| Playlists (collections) | **Built** (M5B), local only: create, rename, delete, reorder, add from a selection, Sing all, queue all; in backups. No imported or catalog playlists, no Link change tracking |
| Find Moved Downloads, download-history exclusion, shadow rows | **Cut** (Kalao's downloads live in `media/`; relinking covers moved folder files) |
| CUE sheets and splits | **Cut** (needs ranged playback; rare for karaoke) |
| Mixes, external player, volume normalisation, quality labels, song-tap setting, genre-separator setting | **Cut** (Home has Continue singing and Recently played; a tap opens Now playing; genres split on `;`, `/` and `,`, the separators in Mornye's `tags/separators.rs`) |
| Network sources, Mornye Link library sync, iOS bookmarks, Android Auto browsing, cover content provider, desktop walk, watcher and drop target | **Cut** (desktop folders come with `desktop/`, M8.7) |

### 7.4 Files

| Mornye | Kalao | Status |
| --- | --- | --- |
| `providers/local_library_provider*.dart`, `utils/local_library_scan_prefs.dart`, `models/library_scan_failure.dart` | `services/library_folder_service.dart`, `services/library_folder_store.dart`, `providers/library_folder_provider.dart`, `models/library_folder.dart` | Built Kalao-sized (M4.13); M5B added unavailable/relink, offline state, auto scan, full rescan, folder covers and converted formats |
| `screens/settings/library_settings_page*.dart` | `screens/settings/library_folders_screen.dart` | Built Kalao-sized; M5B added auto scan, Force full scan, Clean up missing songs, Review duplicates, Find missing artwork |
| `MainActivitySafScan.kt`, `MainActivityLibraryScanCalls.kt`, `SafTreeListing.kt`, `MainActivitySafLeases.kt` | `MainActivityLibraryFolderCalls.kt` | Built Kalao-sized; M5B added image files, offline volumes and `copyDocumentToFile` |
| `rust_backend/crates/core/src/cover/folder.rs` (image-name rule) | `utils/folder_cover.dart` | Ported, with its tests |
| `mobile/src/tags.rs` `open_audio_file` (descriptor duplicate) | `kalao-audio::open_file` (`lent.rs`), used by the decoder and `probeAudio` | Copied (ADR-018) |
| `providers/library_{browse,counts,genres,directory,artist_songs}_provider.dart`, `controllers/library_tracks_folder_data.dart` | `services/library_browse.dart` + `providers/library_browse_provider.dart` | Adapted to `song` |
| `screens/{local_album_screen,library_artist_screen,library_directory_screen}.dart`, `widgets/{library_directory_view,library_fast_scroller,library_view_toggle,library_track_selection_bar,library_selection_playback_actions,animated_library_sliver_grid}.dart` | `screens/library/{library_pages,library_filter_sheet}.dart`, `widgets/library/{paged_song_list,library_actions}.dart` | Adapted (Kalao's theme, no glass widgets) |
| `services/library_search.dart` (word rule) | `LibraryDatabase.search` | Rule merged into Kalao's search |
| `services/library_duplicates.dart`, `library_cleanup.dart` | `services/library_maintenance.dart`, `LibraryFolderService.cleanupMissing` | Adapted |
| `services/library_album_artwork.dart`, `providers/library_album_artwork_provider.dart` | `services/library_maintenance.dart`, `providers/album_artwork_provider.dart` | Adapted (no motion artwork) |
| `services/library_collections_database.dart`, `providers/library_collections_provider.dart`, `models/library_collections.dart` | `services/playlist_store.dart` (with its `Playlist` model), `playlistsProvider` | Adapted (local playlists only) |
| `core::tags`, `core::cover/library.rs`, `native_library*`, `library_metadata.rs`, `extensions/backend/library*`, `services/library_{mixes,reorganizer,shadow_sql,file_sizes,lyrics_search,native_adapter,ingestion_store}.dart`, `conversion_library_service.dart`, `cue_split_library_service.dart`, `media_library_browser.dart`, `controllers/library_re_enrich_all.dart`, `local_track_batch_actions.dart`, `queue_library_*`, `SafCue*.kt`, `SafScanCheckpoint.kt`, `LibraryScanExitInfo.kt`, `CoverContentProvider.kt`, `AndroidLibraryCovers.kt`, the `link/*` and `network_library_*` files | — | Cut (§7.3) |
