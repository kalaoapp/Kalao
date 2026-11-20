# Implementation Guide

How each subsystem is built. Structure and ownership are in ARCHITECTURE.md, the Mornye file map in MORNYE_REUSE.md, libraries in LIBRARIES.md, tasks in ROADMAP.md. Feature numbers refer to FEATURES.md.

## 1. Backend method table

Every Rust call is a name in `kalao-mobile`'s dispatch (`invoke_application(method, args_json) -> String`), mirrored by a typed static method in `PlatformBridge` and, later, in the desktop C ABI crate. Names are camelCase. The lists in code are the source of truth: `METHODS` in `rust_backend/crates/mobile/src/backend.rs` and `nativeBackendMethods` in `MainActivity.kt`.

Implemented:
- **Rust:** `initBackend`, `getBackendInfo`, `getLogs(sinceIndex)`, `clearLogs`, `setLoggingEnabled`; player `playerLoad`, `playerPlay`, `playerPause`, `playerStop`, `playerSeek`, `playerSetVolume`, `playerSetStemGains({vocals, instrumental})`, `playerSetKey(semitones)`, `playerSetTempo(rate)`, `playerSetLoop(startMs?, endMs?)`, `playerSwitchTrack`, `playerState`; import `probeAudio(path, coverBase?)`, `pairImportFiles(files)`; lyrics `parseLyrics(raw, format?)` (`lrc`, `elrc`, `ttml`, `plain` or detected), `exportLyrics(doc, format)` (`lrc`, `elrc`), `detectSections(lines)`, `annotateLyrics(lines, layers)` (`pinyin`, `furigana`, `romaji`), `convertChinese(texts, to)` (`s2t`, `s2tw`, `s2hk`, `t2s`).
- **Native data jobs:** `hash_file`, `rebuildSearchKeys`, `backupWrite`, `backupInspect`.
- **Kotlin:** `getAndroidSdkVersion`, `setScreenAwake`, `start/update/stopBackgroundWork`, `readLastCrashReport`, `clearLastCrashReport`, `recordAppRuntimeError`, SAF `createDocument`, `pickDocumentTree`, `copyFileToDocument`, `writeFileToTree`, `listDocumentTree`, `deleteDocument`, `takeSharedFiles`, `getSupportedAbis`, `installApk`.
- **Event channel:** `com.brinsley.kalao/player_position_stream` (Kotlin polls `playerState`, 30 Hz while playing).

The planned set, by group (names not listed above are not built yet):

| Group | Methods |
| --- | --- |
| Lifecycle | `initBackend(paths)`, `getBackendInfo`, `getLogs(sinceIndex)`, `clearLogs`, `setLoggingEnabled`, `releaseMemory` |
| Player | `playerLoad(songId, sources, startMs)`, `playerPlay`, `playerPause`, `playerSeek(ms)`, `playerStop`, `playerSetVolume`, `playerSetStemGains({vocals, instrumental, original})`, `playerSwitchTrack(kind)`, `playerSetKey(semitones)`, `playerSetTempo(rate)`, `playerSetLoop(startMs?, endMs?)`, `playerPrefetch(sources)`, `playerState` |
| Mic | `micStart(mode: scoring|monitoring|recording, options)`, `micStop`, `micSetMonitorMix(gain, reverb)`, `measureLatency` |
| Import | `probeAudio(path, coverBase?)` (tags, duration, codec, decodability, embedded cover), `pairImportFiles(files)` |
| Lyrics | `parseLyrics(raw, format?)`, `exportLyrics(doc, format)`, `annotateLyrics(lines, lang, layers)`, `convertChinese(text, to)`, `detectSections(lines)` |
| Translation | `translateLines(texts, src, dst, contactEmail?)` |
| Stems | `stemsModels`, `stemsDownloadModel(id)`, `stemsSeparate(songId, audioPath, sha256, prefer)`, `stemsCancel(jobId)`, `stemsJobs`, `stemsRemoteTestKey(key, deviceHash)` |
| Scoring | `melodyExtract(vocalPath, sha256)`, `scoringStart(songId)`, `scoringStop` → `ScoreReport` |
| Extensions | Mornye's names: `installExtension`, `uninstallExtension`, `listExtensions`, `setExtensionEnabled`, `setExtensionSetting`, `invokeExtensionAction`, `extensionHealth`, `addRepository`, `refreshRepository`, `searchLyrics(query)`, `searchMetadata(query)`, `getArtwork(ref)`, `resolveAudio(ref)` |
| Data jobs | `runNativeDataJob({kind, …}, requestId)`, `cancelNativeDataJob(requestId)` with kinds `hash_file`, `rebuildSearchKeys`, `backupWrite`, `backupInspect` |
| Party | `partyHostStart(options)`, `partyHostStop`, `partyApproveGuest(id)`, `partyKick(id)`, `partyPush(event)`, `partyJoin(qrPayload)`, `partyLeave`, `partySend(event)` |

Planned Kotlin-native names: `acquireMulticastLock/releaseMulticastLock` (M8), `getAudioRoute` (M7), `openAppSettings`.

## 2. Audio engine (`kalao-audio`) and `KaraokeDeck` (1.1–1.5, 3.1, 3.2)

**Graph.** One output stream (cpal → AAudio, shared mode, f32 stereo at 48 kHz; AAudio resamples if the route differs. cpal 0.16 does not set `PerformanceMode::LowLatency`; the scoring work in M7 revisits this. The stream is requested directly because querying the default config on Android goes through JNI, which the library does not set up). Up to three sources per song: `original`, `instrumental`, `vocals`. Each source has a decoder thread (Symphonia) → `rubato` resampler → `ringbuf` SPSC buffer (≈ 500 ms). The audio callback pulls the same frame count from every buffer, applies per-source gains, sums into a stereo bus, runs the stretcher, then the output gain and a soft limiter.

**Source sets.**
- *Original + instrumental files* (user imported both): play both; `switchTrack` crossfades their gains.
- *Stems* (separated): play `vocals` + `instrumental`; "original" = both at unity, "instrumental" = vocals at 0, vocal-guide blend (1.3) = vocals at 0–100%.
- *Original only*: one source; karaoke features ask to separate first (4.1).

**Sync.** All decoders seek to the same sample index: a seek locks each source's worker and ring consumer, so the callback outputs silence for that block, then the decoders refill. The callback waits until every unfinished source has a full block, so sources never slip apart. Gains change with a 10 ms ramp; `switchTrack` uses a 150 ms equal-power crossfade. One parameter drives both: the vocal level `v` (0–1). For an original + instrumental pair the gains are sin(vπ/2) and cos(vπ/2); for stems, vocals = `v` and instrumental = the backing level. The bus ends with a soft limiter (linear to 0.8, tanh knee). Because every source passes through one bus and one clock, stems never drift.

**Key and tempo (1.4).** One Signalsmith Stretch instance on the mixed stereo bus: `setTransposeSemitones(k)` for ±6 semitones, time ratio for 50–150% tempo. When both are neutral the stretcher is bypassed (no latency, no CPU). `signalsmith-stretch` 0.1.3 (`Stretch::preset_cheaper`, which splits each spectral block's work across callbacks; `preset_default` computes a whole 120 ms block inside one callback and stuttered on Android's small AAudio buffers), created on the control thread at the first load (outside the mixer lock, then run over half a second of tone and reset, so its first blocks — buffers and FFT tables touched for the first time — are not in the audio callback; doing that on the first speed change stuttered on Android). With the stretcher engaged a callback of `n` frames mixes `n × tempo` source frames (the fraction carries to the next callback) and stretches them to `n`; the position advances by the source frames mixed, so it stays in song time, and while playing it is reported behind by the stretcher's input and output latency. A seek or load resets the stretcher. Key and tempo return to neutral when another song is loaded.

**Clock.** `position = sourceFramesConsumed / sourceRate − outputLatency`, where output latency comes from AAudio timestamps (`getTimestamp`) via cpal's output callback info. In practice cpal 0.16's AAudio backend measures the callback instant from stream creation but the playback instant on CLOCK_MONOTONIC, so the difference is the device uptime; latencies above 500 ms are treated as 0 (`plausible_latency_us`), which on Android leaves the position uncorrected for output latency. With tempo ≠ 1, source frames advance at `rate` per output frame. The frames handed to the output move in callback-sized steps (about 45 ms on the emulator, with late callbacks and several at once when a stream starts), so on a device the reported position comes from `clock.rs`: it advances with the wall clock × tempo from where playback started, never past those frames (it holds only when the output starves), and re-anchors on play, seek, load and stop. This keeps Dart's interpolation within ±30 ms of the engine (measured on the emulator before: up to 173 ms). Manual output (tests) reports the frames exactly. Kotlin polls `playerState` (the whole state as JSON, including `positionMs`, `playing` and `tempo`) every 33 ms while playing and forwards changed payloads on `player_position_stream`; `KaraokeDeck` advances the last position by its own stopwatch × tempo between events for smooth 60 fps lyric sweeps.

**Loops (3.1).** `setLoop(a, b)` repeats song time `a..b`; Learn mode sets it from the held line or lines. The callback cannot move the decoders, so on reaching `b` it flags the loop thread (`kalao-loop`), which seeks every source to `a`; the output is silent for the few milliseconds until the rings refill (the planned 20 ms crossfade at the seam is not built). Loops shorter than 250 ms are refused, and loading a song clears the loop.

**KaraokeDeck.** `services/karaoke_deck.dart` wraps the engine (commands through `PlatformBridge`, state from the position stream, interpolated with a local stopwatch). Kalao has a single deck type, so `PlayerController` (`providers/player_provider.dart`) talks to it directly; it also advances the queue when the engine reports a song completed. `playerPrefetch` (warming the next song's decoders) is not built.

**Media session (1.5).** `KalaoAudioHandler` on the published `audio_service` package (notification, lock screen, artwork from the song's cover, headset buttons); `AudioFocus` with `audio_session` (duck on transient loss, pause on loss, resume after a transient loss, pause on becoming-noisy).

## 3. Import and library (1.6, 1.7, 6.1, 6.2)

1. *Import* (`file_picker`, which returns SAF content URIs, or files shared to Kalao): each picked audio and lyrics file is streamed into `import_staging/`. Folder import is not built.
2. *Probe and pair:* `probeAudio` reads each staged audio file; `pairImportFiles` (`core::pairing`) proposes an instrumental and a lyrics file for each original from the same pick by filename similarity (tokens such as `instrumental`, `inst`, `karaoke`, `off vocal`, `backing`, `伴奏`, `カラオケ`, `オフボーカル`) and duration within ±2 s. Originals already in the library (same SHA-256) are marked as duplicates. The user confirms in the import sheet.
3. *Copy:* `hash_file` hashes each file, which is then copied into app storage as `media/<sha256>.<ext>` (skipped when that file exists). This makes backups, stems and restore independent of SAF permissions.
4. *Probe the copy:* `probeAudio` reads tags (title, artist, album, ISRC, embedded lyrics), the front cover (written to `covers/`), duration, codec and whether Symphonia can decode it. Undecodable formats are converted once to FLAC with FFmpegKit in Dart (`main.dart` `_convertWithFfmpeg`) and the converted file replaces the copy.
5. *Store:* `library_database.dart` inserts `song` and `media_file` rows in one transaction; a paired or embedded lyrics text is imported through `LyricsService`.
6. *Search keys (6.2):* a `rebuildSearchKeys` native data job returns `song_search` rows: normalised title/artist, toneless pinyin and initials for Chinese, romaji for Japanese. Library search normalises the query the same way (`library_search.dart`) and ranks prefix matches before substring matches.
7. *Home (6.1):* search, Continue singing (session restore), Recently played, Recently added.

## 4. Lyrics (2.1–2.3, 2.6–2.8, 2.13)

**Model (Dart).** `lib/models/lyrics.dart`: `LyricDocument` (`timed`, `offsetMs`, `format`, `sourceLang`), `LyricLine` with `time`, `end`, `words` (`LyricWord`: time, end and its UTF-16 start in the line text), `voice` (`v1`, `v2`, … or `bg`), `translation`, `section`, `sectionBreakBefore`, `layers` (`LyricLayerKind` → `LyricLayer` of `RubySegment`s, each a UTF-16 range and a reading) and the display-only `variantText`. Untimed lyrics use `time = Duration.zero` for every line and `timed = false` on the document (manual stepping, 2.7).

**Parsing (2.8).** `core::lyrics::doc`: LRC with offsets and multiple time tags per line; enhanced LRC, where a word runs from the `<mm:ss.xx>` tag before it to the tag after it (so both `<t>word <t>word <end>` and `<start>word<end><start>word<end>` are read), a tag that ends the row is the line end, `v1:`/`v2:` prefixes are duet voices and `[bg:…]` rows are backing lines; TTML through Mornye's Apple payload reader (`payloads::ttml`), which yields the same enhanced LRC plus head translations. A lone `v1` voice on every line is dropped (solo song). Plain text: one line per row, blank rows = section breaks. Export (`exportLyrics`): LRC keeps line starts and writes a blank timed row for each break (it also ends the line before it); enhanced LRC also writes word tags, line ends, section rows (`[t][Chorus]`), voices and backing rows, and parses back to the same lines. TTML export is not planned.

**Sections (2.2).** `core::sections` (ported from the POC's section-marker rules and tests, incl. the `【】｛｝「」『』❲❳` bracket forms): markers like `[Verse]`, `Chorus:`, `(Bridge)`, `【副歌】`, `主歌`, `副歌`, `间奏`, `[サビ]` become `LyricSection` on the next line and are removed from the text; blank lines become `sectionBreakBefore`.

**Pinyin (2.3).** `core::annotate::pinyin`:
1. Read with `pinyin_pro` (Rust port of `pinyin-pro`, the POC's library), which segments and resolves polyphonic characters in context (`重要` zhòng vs `重新` chóng).
2. Tone diacritics: mark goes on `a`/`e`, on `o` in `ou`, otherwise on the last vowel; `ü` kept (`lǜ`), `v` input normalised to `ü`.
3. Er-hua: `儿` after a syllable merges into an `r` suffix on that syllable (`哪儿` → `nǎr`) when the word is in the er-hua list; otherwise `ér`.
4. Alternative brackets: the POC's bracket rules are its section-marker forms (`[]【】｛｝「」『』❲❳`), handled by `core::sections`; Han text inside `（）`/`()` is annotated like any other text.
5. Alignment: one `RubySegment` per Han character (or per word for multi-character readings); non-Han text gets no segment, so spaces and Latin never shift the alignment (the POC's whitespace bug).
The POC's pinyin, er-hua, bracket and whitespace test cases in `poc-webapp` are ported as Rust tests (`crates/core/src/annotate/pinyin.rs` and `crates/core/src/sections.rs`) and pass unchanged.

**Japanese (2.4).** `core::annotate::japanese`: `lindera` 6.2 with the IPADIC dictionary embedded tokenises and gives katakana readings → converted to hiragana; segments are emitted only over kanji runs (okurigana stays unannotated: kana in the word must appear in the reading as written, each kanji run takes what lies between, and a reading that does not fit goes over the whole word). `wana_kana` converts readings to romaji, one romaji segment per token, with the particles は/へ/を as `wa`/`e`/`o`. Lyrics with kana are treated as Japanese (furigana and romaji, no pinyin); the same rule gives kanji titles a romaji search key. Dart shows furigana above the text and the romaji joined under it, each with its own toggle.

**Traditional ↔ Simplified (2.5).** `core::annotate::chinese_variant`: OpenCC conversion (`s2t`, `t2s`, `s2tw`, `s2hk`) through `ferrous-opencc`; the target variant is a setting (as written, Simplified, Traditional, Taiwan, Hong Kong). The conversion is applied when lyrics are loaded for display (`LyricsService.withVariant` → `LyricLine.variantText`) and is never stored; a line whose conversion changes its length keeps its own text so readings and word ranges stay aligned.

**Display (2.1).** Each layer is toggled in the lyrics options sheet (`lyrics_options_sheet.dart`); order: reading above text (pinyin/furigana as ruby), romaji below, translation below. `ruby_lyric_line.dart` lays out ruby per segment using `TextPainter` measurements; `lyric_line_view.dart` stacks the layers for one line. Text sizes S–XXL scale the lyric font (`LyricsSize` in settings).

**Sync (2.6) and sweep (2.13).** Active line = binary search over line start times using the interpolated engine position plus a per-song offset (`offsetMs` in the lyric document JSON, adjustable ±5 s in 50 ms steps in the lyrics options sheet; an offset change edits the current version in place). Backing lines are never the active line; they light up with the lead line they follow. Sweep (`utils/lyrics_timeline.dart` `sweptChars`): with word timing the highlight crosses each word during that word and rests between words; lines without word timing sweep linearly from the line start to its end (the next lead line's start when it has none), capped at 10 s. `SweepText` (`widgets/ruby_lyric_line.dart`) draws the line twice and clips the highlight layer to the boxes of the sung characters; the clip listens to one `ValueNotifier` updated by the lyric ticker, so a frame repaints one line. The sweep can be turned off (the active line is then one colour). Accuracy target ±30 ms against the engine clock: `kalao-audio` renders a click track and compares the reported position with the click in the output (tempo 1 and 0.5); `lyrics_test.dart` models 30 Hz position reports and checks when lines turn active; `integration_test/lyrics_timing_test.dart` repeats it on a device.

**Sync editor (2.9).** `controllers/lyrics_sync_editor_controller.dart` (`LyricsSyncEditor`: the draft, taps, nudge, undo; no Flutter widgets) + `screens/lyrics_sync_screen.dart` (route `/player/sync`, opened from the lyrics options sheet). A tap stamps the start of the cursor's line or word; a tap held ≥ 350 ms also stamps the end at release; words are one per CJK character and one per whitespace-separated word otherwise (`splitWords`, punctuation stays with its neighbour); the tap position is the interpolated engine position minus the tap-latency setting (0–200 ms, default 40) scaled by the tempo, and the engine position already subtracts output latency; speeds 50/75/100% through `playerSetTempo` (reset to 100% on leaving); nudge ±10/±50 ms moves the last stamped word or line (or a line selected by tapping it, which also moves the cursor there to re-time from it); an existing timed document opens with its timing and offset applied. Save writes a new version (`source_kind = userEdited`, offset 0, annotation layers carried over, word timing kept for lines whose every word was stamped); the screen also exports LRC/eLRC.

## 5. Modes (3.1, 3.2)

- **Learn mode:** original vocals; all annotation layers available; translation; loop a line (long-press it); A–B repeat (long-press a second line); slow-down presets 50/75/90/100%; line stepping with ↑/↓ and tap.
- **OG Karaoke mode:** instrumental (or vocals at the user's guide level); lyrics in large type, two lines visible, word sweep; countdown dots for gaps ≥ 4 s before the next line, including the intro; next singer from the queue shown at the end; mic monitoring and scoring when enabled (M7). Screen kept awake while playing.
- Mode is a per-play choice on the now-playing screen; the last choice per song is remembered.
- `PlayerController` holds the mode (`setMode` switches the track and stores `song.last_mode`); a song opens in the mode last used for it, else Learn. Learn tools: long-press a line to repeat it at once, then long-press another to repeat everything between the two (the repeated lines stay marked; a long-press on one of them, or the Stop repeating chip beside the speed chips, ends it; `L` / gamepad Y repeat the current line). The active line is re-centred when the layout changes (rotation, lyric size), jumping near lines the lazy list has not built yet. Karaoke uses `KaraokeLyricsView` for timed lyrics (`KaraokeFrame.at` decides the current line, the next line and the countdown) and falls back to the scrolling view for untimed ones. The countdown and keep-screen-on can be turned off in the lyrics options.

## 6. Queue (6.5) and favorites (6.3)

`QueueStore` (`library_queue_store.dart`) over `queue_item` in `kalao_app_state.db`, with Kalao fields `singer` (free text; parties will use the guest name) and `mode`; `queueProvider`/`QueueActions` expose it, `queue_tab.dart` shows it, and `PlayerController.playNextInQueue` runs when the engine reports a song completed and skips entries whose song was deleted. Favorites are a `favorite` table keyed by `song.id`.

## 7. Stats (6.7)

`HistoryDatabase.stats` aggregates the `play` rows (`song_id`, `started_at`, `duration_ms`, `mode`, `score`, `singer`) in SQLite — totals, the last 7 days, most played, most practised (Learn time), best scores — and `stats_screen.dart` shows them. `GROUP BY` over the indexed table is fast enough that no data job is needed.

## 8. Stems

See STEM_SEPARATION.md. Engine-facing details: stems are FLAC files `stems/<sha256>/{vocals,instrumental}.flac` at 44.1 kHz stereo; `playerLoad` receives them as `vocals` + `instrumental` sources. The job runs inside `BackgroundWorkService` with kind `stems` (foreground type `dataSync`), notification text supplied by Dart, progress on `stem_progress_stream`.

## 9. Scoring (3.3) and monitoring (3.4)

**Reference melody.** After stems exist, `melodyExtract` runs pYIN on the vocal stem (mono, 16 kHz, 10 ms hop) → f0 + voicing per frame → median-smoothed → stored as `melody/<sha256>.bin` (u16 cents per frame, 0 = unvoiced). Notes are derived by segmenting stable pitch runs ≥ 80 ms for the pitch-lane display.

**Live pitch.** `micStart(scoring)` opens an AAudio input stream (cpal, `LowLatency`, 48 kHz mono) → 16 kHz → YIN per 10 ms frame with a 40 ms window → cents + confidence. The mic timeline is shifted by measured round-trip latency (`measureLatency`: a chirp played and recorded once per output route; cached per route; Bluetooth routes show a warning and disable monitoring).

**Score.** Per voiced reference frame where the singer is voiced: error = distance in cents folded to one octave; frame score 1.0 within ±50 cents, linearly falling to 0 at ±300. Line score = mean frame score × coverage (voiced singer frames / voiced reference frames), 0–100. Song score = duration-weighted line mean. `pitch_stream` sends `{refCents, micCents, confidence}` at 50 Hz to `pitch_lane.dart` (scrolling note lane like the reference notes, with the live trace).

**Monitoring.** In monitoring mode the input is mixed into the output bus in the same callback (full-duplex on one cpal host) with gain and a small freeverb-style reverb/echo; enabled only on wired/USB routes (Mornye `audio_route_info.dart`).

**Recording (3.5).** `micStart(recording)` writes the mixed bus (instrumental + vocal) to FLAC in app storage; user-initiated, listed under Recordings, shareable via `share_plus`; never uploaded.

## 10. Extensions (5.x, 2.10, 2.11, 1.8, 6.4, 6.6)

Built on Mornye's `extensions` crate and Dart extension UI (MORNYE_REUSE.md §3–4). Kalao specifics:
- Capabilities map to Mornye provider types: `lyrics` (Mornye lyrics provider), `metadata` + `artwork` (Mornye metadata provider), `audio` (Kalao's `resolveAudio`; Kalao streams/downloads the URL itself, the extension never handles bytes).
- **Lyric fetch (2.11):** `searchLyrics` queries enabled lyrics extensions in priority order in parallel (6 s timeout each); candidates are ranked with Mornye's `core::lyrics::matching` (title/artist similarity, duration ±3 s) plus a format bonus (`elrc` > `lrc` > `plain`). The user's priority (Mornye `lyrics_provider_priority_page.dart`) breaks ties; a provider picker (Mornye `lyrics_provider_picker.dart`) lets the user choose another candidate.
- **Language detection (2.10):** Mornye `lyrics_language_guess.dart` on the chosen lyrics; the result picks annotation layers (zh → pinyin + Trad/Simp, ja → furigana + romaji).
- **Streaming (1.8):** `resolveAudio` URL → `KaraokeDeck` network source with HTTP range reads in Rust (`kalao-network`) and a byte cache (Mornye's `network_playback_cache.dart` policy); "Download for offline" (6.6) saves the stream into `media/` like an import.
- **Metadata/artwork (6.4):** `searchMetadata` merges results across extensions; artwork is cached by Mornye's cover cache.

## 11. Translation (2.12)

- Client: `kalao-providers::mymemory`. `GET https://api.mymemory.translated.net/get?q=<text>&langpair=<src>|<dst>[&de=<email>]`.
- Limits: `q` ≤ 500 bytes UTF-8 (longer lines are split at punctuation); free quota about 5,000 characters/day anonymously, about 50,000/day with a contact email. The optional email is a user setting (stored locally, never sent elsewhere) with an explanation of why it helps.
- Batching and cache: Mornye's `LyricsTranslationSource` sends each distinct line once (a repeated chorus costs nothing) and caches results by SHA-256 of the line list + language pair. Lines are requested with concurrency 2.
- Errors: a quota warning in `responseData.translatedText` or HTTP 429 → stop for the day, keep partial results, show "Daily translation limit reached". `responseStatus` ≠ 200 → line left untranslated.
- Language codes: Kalao's `zh-Hans` → `zh-CN`, `zh-Hant` → `zh-TW`, `ja` → `ja`, etc. (table in `lyrics_translation_languages.dart`).
- Translations are `origin = translator`; users can edit a line, which marks it `human`.

## 12. Backup and restore (7.x)

Dart `backup_service.dart` decides what goes in and merges what comes out (`backup_screen.dart` drives it, `BackupController` runs one job at a time inside `BackgroundWorkService` kind `backup`); Rust `kalao-mobile::native_backup` streams files into and out of the ZIP in the `backupWrite` / `backupInspect` data jobs, so media never passes through the UI isolate.
- Export and inspection: snapshots are `VACUUM INTO` copies of the live databases; covers always go in, imported audio when the user includes it. `backupInspect` checks every name (relative, plain characters, no `..`), the entry count, the expansion ratio, the declared size and the SHA-256 of every entry and the format before anything is kept, and extracts into `backup_work/`. Dart then runs `PRAGMA integrity_check`, refuses a newer schema and migrates an older one on the copy, and builds the preview. Merge and Replace run in Dart with the backup database `ATTACH`ed to the live connection, in one transaction per database, so there is no `backupRestore` job and no database swap; absolute file paths are rewritten to this device's folders.
- Archive: `.kalaobackup` = ZIP with `manifest.json` (format version, app version, created_at, categories, counts, per-entry SHA-256), `library.db`, `history.db`, `app_state.db`, `settings.json` (non-secret preferences), `covers/`, optional `media/`; later `extensions/*.kalaoext` + `extensions.json` (M5) and optional `stems/` (M6).
- Restore: Merge matches songs by `song_key` and media by SHA-256 (media files are named by it); the backup's lyrics become a new version when their `updated_at` is newer, keeping this library's `human` layers on lines whose text did not change; favorites are unioned and plays de-duplicated by `started_at` + `song_key`; preferences stay. Replace first writes a safety backup to `backups/` (the newest three are kept), then swaps every table except `backup_run` and applies the backup's preferences, keeping this device's own keys (`AppSettings.deviceKeys`: setup state, custom font path, backup folder and schedule).
- Scheduled backup (7.4): Dart checks on app start and resume whether a backup is due (daily/weekly) and runs it into the user's chosen SAF folder (`pickDocumentTree`, persisted permission; `writeFileToTree`), keeping the last N files named `kalao-YYYY-MM-DD-HHMM.kalaobackup` (other files in the folder are never touched); the result is logged in `backup_run`. A failed run is retried after an hour, not on every resume. There is no background scheduler, so a due backup runs the next time the app is opened. A manual backup is saved where the user chooses (`createDocument`, `copyFileToDocument`).
- POC import (7.6): a one-off script in the private POC (`poc-webapp/scripts/export-kalao.ts`, never published) exports one user's songs, lyric lines (text, translation, furigana, section breaks), favorites and plays to `kalao-poc.json` (`{format: "kalao-poc", version: 1, songs: [...]}`). `PocImportService` (Dart; no data job needed) attaches them to songs already imported, matched by normalised title + artist, since the POC's audio is not migrated; unmatched songs are listed. Readings are generated as usual; POC translations and furigana (one reading per line) are kept as `human`.
- Secrets (7.5): backups never read secure storage, and the manifest records `secrets: false`. Prompting for secrets of restored extensions arrives with extensions (M5.3).

## 13. Parties (8.x)

Derived from Mornye Link (`crates/link`):
- **Host:** `partyHostStart` starts an HTTPS server (self-signed certificate from `rcgen`, as Link) and a WebSocket endpoint on the LAN, advertises `_kalao-party._tcp` via mDNS (`mdns-sd`; Dart discovery with `bonsoir`), and opens a 6-digit PIN pairing window.
- **Join:** the QR code encodes `kalao://party?h=<ip:port>&fp=<cert sha256>&pin=<pin>&name=<room>`. The guest verifies the certificate fingerprint and proves the PIN like Link (`HMAC-SHA256(key=PIN, "kalao-party-v1:" + fingerprint + ":" + deviceId)`; five bad proofs close the window). Manual join: pick the room from mDNS and type the PIN. The host approves each guest.
- **Protocol (WebSocket JSON):** `hello`, `library.page` (host's songs: id, title, artist, has_stems, has_timed_lyrics), `queue.add {songId, singer}`, `queue.move`, `queue.remove`, `queue.state`, `now_playing {songId, singer, mode}`, `position {ms, monotonic}` (2 Hz, guests interpolate), `lyrics {doc}` (sent once per song), `score {singer, line, total}`, `end`. Guests can only add, move and remove their own entries; the host can do everything.
- **TV view (8.5):** the host also serves a read-only lyrics page over plain HTTP at `http://<ip>:<port>/tv/<roomToken>` (HTML + WebSocket, no Google Cast); open it in a TV browser or cast the host screen with the system screen-mirroring.

## 14. Updates (9.8)

Once a day if enabled, `UpdateService` (`http`) reads `api.github.com/repos/kalaoapp/Kalao/releases/latest`, compares versions, picks the APK for the device ABI, and `update_dialog.dart` shows the changelog. Only when the user taps Update: download to cache with progress, verify the SHA-256 from the release's `SHA256SUMS.txt`, then hand the APK to the package installer (`installApk`, `REQUEST_INSTALL_PACKAGES`). "Open release page" is always offered.
- `UpdateController` (`update_provider.dart`) holds the state; the device ABIs come from Kotlin (`getSupportedAbis`); assets are named `Kalao-<version>-{arm64,arm32,x86_64,universal}.apk` as `release.yml` publishes them. The APK is downloaded to `cache/updates/` and hashed with the Rust `hash_file` job; `installApk` only accepts a file from that folder and shares it through a `FileProvider`. Without the "install unknown apps" permission it opens that setting instead. Old downloads are removed at the next check. The last check time is in shared_preferences (`update_checked_at`).

## 15. Diagnostics (9.5)

Dart `AppLogger` + `LogBuffer` (ring buffer; tokens, keys and MyMemory's `de=` redacted by `redactDiagnosticText`) and the Rust log buffer (`getLogs`), merged in `log_screen.dart`; shared as a text file through the share sheet (`share_plus`). Rust-side redaction arrives with the extension runtime (M5). `app_crash_service.dart` and `AppCrashReporter.kt` keep the last crash report locally and show `app_crash_banner.dart` on next start with "Copy" and "Open GitHub issue" (pre-filled template, nothing sent automatically).

## 16. Settings

`AppSettings` (`models/settings.dart`, hand-written JSON that ignores unknown keys) is one JSON object in shared_preferences. Today: setup and tutorial state, What's New version, theme mode, locale, Material You, verbose logging; lyric size and custom font; lyric layers (pinyin, furigana, romaji, translation), Chinese variant, word sweep, tap latency, countdown, keep screen on; backup folder, schedule, keep N, include media; update check. `deviceKeys` lists the values a Replace restore keeps from this device. Later groups: lyrics fetching and provider priority (M5), stems (M6), translation target and MyMemory email (M6), mic latency and monitoring (M7), party (M8), extension developer mode (M5).

## 17. Testing

- **Rust:** unit tests per crate; fixtures for annotate (POC cases), LRC/eLRC/TTML round trips, sections, pairing, search keys, backup archive round trip and unsafe archives; audio engine tests on rendered buffers (stem sync by phase cancellation, seek accuracy, crossfade curve, gain ramps, tempo/key, loops, click-track timing). Later: MyMemory response parsing, party pairing proofs.
- **Kotlin:** `MainActivityRoutingTest`.
- **Dart:** unit and widget tests (`flutter test`) for services, providers, lyric timing and screens, over `FakeBackend` and `sqflite_common_ffi`. Golden tests for ruby layout are not written yet.
- **Integration (`integration_test/`):** lyric timing accuracy on a device (±30 ms; `lyrics_timing_test.dart`, `fvm flutter test integration_test`). Later: playback and session restore, import pairing, backup round trip, stems job resume after process kill, party with two emulators.
- **CI:** `ci.yml` (see the repository CLAUDE.md for the job list).
