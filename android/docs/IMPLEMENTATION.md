# Implementation Guide

How each subsystem is built. Structure and ownership are in ARCHITECTURE.md, the Mornye file map in MORNYE_REUSE.md, libraries in LIBRARIES.md, tasks in ROADMAP.md. Feature numbers refer to FEATURES.md.

## 1. Backend method table

Every Rust call is a name in `kalao-mobile`'s dispatch (`invoke_application(method, args_json) -> String`), mirrored by a typed static method in `PlatformBridge` and, later, in `kalao-desktop/src/dispatch.rs`. Names are camelCase like Mornye's. Groups:

Implemented so far (M0–M3): `initBackend`, `getBackendInfo`, `getLogs(sinceIndex)`, `clearLogs`, `setLoggingEnabled`; player `playerLoad`, `playerPlay`, `playerPause`, `playerStop`, `playerSeek`, `playerSetVolume`, `playerSetStemGains({vocals, instrumental})`, `playerSetKey(semitones)`, `playerSetTempo(rate)`, `playerSetLoop(startMs?, endMs?)`, `playerSwitchTrack`, `playerState`; import `probeAudio(path, coverBase?)`, `pairImportFiles(files)`; lyrics `parseLyrics(raw, format?)` (`lrc`, `elrc`, `ttml`, `plain` or detected), `exportLyrics(doc, format)` (`lrc`, `elrc`), `detectSections(lines)`, `annotateLyrics(lines, layers)` (layers `pinyin`, `furigana`, `romaji`), `convertChinese(texts, to)` (`s2t`, `s2tw`, `s2hk`, `t2s`); data jobs `hash_file`, `rebuildSearchKeys`; event channel `com.brinsley.kalao/player_position_stream` (Kotlin polls `playerState`, 30 Hz while playing); Kotlin-native `getAndroidSdkVersion`, `setScreenAwake`, `start/update/stopBackgroundWork`, `readLastCrashReport`, `clearLastCrashReport`, `recordAppRuntimeError`; M4 data jobs `backupWrite`, `backupInspect` and Kotlin-native `createDocument`, `pickDocumentTree`, `copyFileToDocument`, `writeFileToTree`, `listDocumentTree`, `deleteDocument` (SAF, `MainActivityStorageCalls.kt`), `takeSharedFiles` (`SharedFiles.kt`), `getSupportedAbis`, `installApk` (`MainActivityUpdateCalls.kt`). The method list lives in `rust_backend/crates/mobile/src/backend.rs` (`METHODS`) and `MainActivity.nativeBackendMethods`.

| Group | Methods |
| --- | --- |
| Lifecycle | `initBackend(paths)`, `getBackendInfo`, `getLogs(sinceIndex)`, `clearLogs`, `setLoggingEnabled`, `releaseMemory` |
| Player | `playerLoad(songId, sources, startMs)`, `playerPlay`, `playerPause`, `playerSeek(ms)`, `playerStop`, `playerSetVolume`, `playerSetStemGains({vocals, instrumental, original})`, `playerSwitchTrack(kind)`, `playerSetKey(semitones)`, `playerSetTempo(rate)`, `playerSetLoop(startMs?, endMs?)`, `playerPrefetch(sources)`, `playerState` |
| Mic | `micStart(mode: scoring|monitoring|recording, options)`, `micStop`, `micSetMonitorMix(gain, reverb)`, `measureLatency` |
| Import | `probeAudio(path)` (tags, duration, codec, sha256), `readCover(path)`, `importConvert(path)` (via FFmpeg when Symphonia cannot decode) |
| Lyrics | `parseLyrics(raw, format?)`, `exportLyrics(doc, format)`, `annotateLyrics(lines, lang, layers)`, `convertChinese(text, to)`, `detectSections(lines)` |
| Translation | `translateLines(texts, src, dst, contactEmail?)` |
| Stems | `stemsModels`, `stemsDownloadModel(id)`, `stemsSeparate(songId, audioPath, sha256, prefer)`, `stemsCancel(jobId)`, `stemsJobs`, `stemsRemoteTestKey(key, deviceHash)` |
| Scoring | `melodyExtract(vocalPath, sha256)`, `scoringStart(songId)`, `scoringStop` → `ScoreReport` |
| Extensions | Mornye's names: `installExtension`, `uninstallExtension`, `listExtensions`, `setExtensionEnabled`, `setExtensionSetting`, `invokeExtensionAction`, `extensionHealth`, `addRepository`, `refreshRepository`, `searchLyrics(query)`, `searchMetadata(query)`, `getArtwork(ref)`, `resolveAudio(ref)` |
| Data jobs | `runNativeDataJob({kind, …}, requestId)`, `cancelNativeDataJob(requestId)` with kinds `hash_file`, `rebuildSearchKeys`, `backupWrite`, `backupInspect` |
| Party | `partyHostStart(options)`, `partyHostStop`, `partyApproveGuest(id)`, `partyKick(id)`, `partyPush(event)`, `partyJoin(qrPayload)`, `partyLeave`, `partySend(event)` |

Kotlin-native names (in `nativeBackendMethods`): SAF picker and I/O (Mornye's), `startBackgroundWork/updateBackgroundWork/stopBackgroundWork` (Mornye's), `setScreenAwake`, `installApk(path)`, `acquireMulticastLock/releaseMulticastLock`, `getAudioRoute`, `openAppSettings`.

## 2. Audio engine (`kalao-audio`) and `KaraokeDeck` (1.1–1.5, 3.1, 3.2)

**Graph.** One output stream (cpal → AAudio, shared mode, f32 stereo at 48 kHz; AAudio resamples if the route differs. cpal 0.16 does not set `PerformanceMode::LowLatency`; the scoring work in M7 revisits this. The stream is requested directly because querying the default config on Android goes through JNI, which the library does not set up). Up to three sources per song: `original`, `instrumental`, `vocals`. Each source has a decoder thread (Symphonia) → `rubato` resampler → `ringbuf` SPSC buffer (≈ 500 ms). The audio callback pulls the same frame count from every buffer, applies per-source gains, sums into a stereo bus, runs the stretcher, then the output gain and a soft limiter.

**Source sets.**
- *Original + instrumental files* (user imported both): play both; `switchTrack` crossfades their gains.
- *Stems* (separated): play `vocals` + `instrumental`; "original" = both at unity, "instrumental" = vocals at 0, vocal-guide blend (1.3) = vocals at 0–100%.
- *Original only*: one source; karaoke features ask to separate first (4.1).

**Sync.** All decoders seek to the same sample index; a seek pauses the callback mix, flushes the buffers, repositions every decoder, prefills, then resumes. (M1: a seek locks each source's worker and ring consumer, so the callback outputs silence for that block; the callback waits until every unfinished source has a full block, so sources never slip apart.) Gains change with a 10 ms ramp; `switchTrack` uses a 150 ms equal-power crossfade. One parameter drives both: the vocal level `v` (0–1). For an original + instrumental pair the gains are sin(vπ/2) and cos(vπ/2); for stems, vocals = `v` and instrumental = the backing level. The bus ends with a soft limiter (linear to 0.8, tanh knee). Because every source passes through one bus and one clock, stems never drift.

**Key and tempo (1.4).** One Signalsmith Stretch instance on the mixed stereo bus: `setTransposeSemitones(k)` for ±6 semitones, time ratio for 50–150% tempo. When both are neutral the stretcher is bypassed (no latency, no CPU). As built (M3.1): `signalsmith-stretch` 0.1.3 (`Stretch::preset_cheaper`, which splits each spectral block's work across callbacks; `preset_default` computes a whole 120 ms block inside one callback and stuttered on Android's small AAudio buffers), created on the control thread the first time key or tempo is not neutral. With the stretcher engaged a callback of `n` frames mixes `n × tempo` source frames (the fraction carries to the next callback) and stretches them to `n`; the position advances by the source frames mixed, so it stays in song time, and while playing it is reported behind by the stretcher's input and output latency. A seek or load resets the stretcher. Key and tempo return to neutral when another song is loaded.

**Clock.** `position = sourceFramesConsumed / sourceRate − outputLatency`, where output latency comes from AAudio timestamps (`getTimestamp`) via cpal's output callback info. As built: cpal 0.16's AAudio backend measures the callback instant from stream creation but the playback instant on CLOCK_MONOTONIC, so the difference is the device uptime; latencies above 500 ms are treated as 0 (`plausible_latency_us`), which on Android leaves the position uncorrected for output latency. With tempo ≠ 1, source frames advance at `rate` per output frame. The frames handed to the output move in callback-sized steps (about 45 ms on the emulator, with late callbacks and several at once when a stream starts), so on a device the reported position comes from `clock.rs`: it advances with the wall clock × tempo from where playback started, never past those frames (it holds only when the output starves), and re-anchors on play, seek, load and stop. This keeps Dart's interpolation within ±30 ms of the engine (measured on the emulator before: up to 173 ms). Manual output (tests) reports the frames exactly. The engine publishes `{positionMs, monotonicNs, playing, rate}` on `player_position_stream` at 30 Hz (on change of state immediately); Dart interpolates with the monotonic clock for smooth 60 fps lyric sweeps.

**Loops (3.1).** `setLoop(a, b)`: when the source position reaches `b`, the engine performs an in-callback seek to `a` with a 20 ms crossfade. "Loop current line" sets `a/b` from the active line's start/end. As built (M3.2): the callback cannot move the decoders, so on reaching `b` it flags the loop thread (`kalao-loop`), which seeks every source to `a`; the output is silent for the few milliseconds until the rings refill. Loops shorter than 250 ms are refused, and loading a song clears the loop.

**KaraokeDeck.** `services/karaoke_deck.dart` wraps the engine (commands through `PlatformBridge`, state from the position stream, interpolated with a local stopwatch). Kalao has a single deck type, so `PlayerController` (`providers/player_provider.dart`) talks to it directly instead of going through Mornye's 2,800-line multi-deck `music_player_service.dart`; queue features arrive with M3.4. The original design was: it implements Mornye's `QueuedPlaybackDeck`. `setNetworkSource`/local source calls map to `playerLoad`; `onPositionChanged`, `onPlayerStateChanged`, `onPlayerComplete` come from `player_position_stream`; `setPlaybackRate` maps to tempo; `queueNextSource` maps to `playerPrefetch` so the next song's decoders warm up. Mornye's `music_player_service.dart` is used with the deck factory returning only `KaraokeDeck`; AutoMix/gapless/EQ/ReplayGain parts are removed.

**Media session (1.5).** Unchanged from Mornye: `audio_service` fork, `audio_session` focus handling (duck on transient loss, pause on loss, pause on becoming-noisy), headset buttons, lock-screen metadata and artwork from `media_session_art_cache.dart`.

## 3. Import and library (1.6, 1.7, 6.1, 6.2)

1. *Import* (`file_picker` 13, which returns SAF content URIs): user picks audio and lyrics files; each is streamed into `import_staging/` (folder import is not in M1).
2. *Pairing:* for each original, Kalao proposes an instrumental and a lyrics file from the same pick by filename similarity (`core::filename` normalisation, then tokens such as `instrumental`, `inst`, `karaoke`, `off vocal`, `backing`, `伴奏`, `カラオケ`, `オフボーカル`) and duration within ±2 s. The user confirms in the import sheet.
3. *Copy:* files are copied into app storage `media/<sha256>.<ext>` (hashing while copying). This makes backups, stems and restore independent of SAF permissions. Duplicates by hash are linked, not copied twice.
4. *Probe:* `probeAudio` reads tags (title, artist, album, ISRC, embedded lyrics), the front cover, duration and codec through Symphonia's metadata reader, which the engine already links; Mornye's 2,700-line `core::tags` (tag writing, download metadata) is not needed for read-only import and is not copied. Undecodable formats are converted once to FLAC with FFmpegKit in Dart (`main.dart`, no separate `importConvert` method) and the converted file is kept.
5. *Store:* Dart `library_database.dart` inserts `song` and `media_file` rows; the embedded cover is written by `probeAudio` to `covers/` and referenced from `song.cover_path` (thumbnails via `Image.file(cacheWidth)`; Mornye's `cover_store` arrives if artwork search needs it in M5.8).
6. *Search keys (6.2):* a `rebuildSearchKeys` native data job writes `song_search` rows: normalised title/artist (Mornye `normalizeLookupText`), toneless pinyin and initials for Chinese, romaji for Japanese. Library search queries title, artist, pinyin, initials, romaji with prefix matching.
7. *Home (6.1):* Mornye's `home_tab` with Kalao sections: Continue singing (session restore), Recently played (`history_database`), Favorites, Recently added.

## 4. Lyrics (2.1–2.3, 2.6–2.8, 2.13)

**Model (Dart).** `lib/models/lyrics.dart`: `LyricDocument` (`timed`, `offsetMs`, `format`), `LyricLine` with `time`, `end`, `words` (`LyricWord`: time, end and its range in the line text), `voice` (`v1`, `v2`, … or `bg`), `translation`, `section`, `sectionBreakBefore`, `layers`; `RubySegment`. Mornye's `romanization`/`romanizationWords` are not stored: readings are layers. Original target shape:
```dart
class LyricLine {            // Mornye fields
  Duration time; Duration? end; String text; List<LyricWord> words;
  String? romanization; List<LyricWord> romanizationWords; String? translation; LyricVoice? voice;
  // Kalao additions
  LyricSection? section; bool sectionBreakBefore;
  Map<LyricLayerKind, LyricLayer> layers;   // pinyin, furigana, romaji, traditional, simplified
}
class LyricLayer { List<RubySegment> segments; LayerOrigin origin; }   // auto | human
class RubySegment { int start; int end; String reading; }              // UTF-16 range in text
```
Untimed lyrics use `time = Duration.zero` for every line and a `timed = false` flag on the document (manual stepping, 2.7).

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

**Display (2.1).** Each layer is toggled in the lyrics options sheet (Mornye `lyrics_options_button.dart`); order: reading above text (pinyin/furigana as ruby), romaji below, translation below. `ruby_lyric_line.dart` lays out ruby per segment using `TextPainter` measurements; it falls back to Mornye's `aligned_lyric_pronunciation.dart` when only word-level pronunciation exists. Text sizes S–XXL use Mornye's `lyrics_text_scale.dart`.

**Sync (2.6) and sweep (2.13).** Active line = binary search over line start times using the interpolated engine position plus a per-song offset (`offsetMs` in the lyric document JSON, adjustable ±5 s in 50 ms steps in the lyrics options sheet; an offset change edits the current version in place). Backing lines are never the active line; they light up with the lead line they follow. Sweep (`utils/lyrics_timeline.dart` `sweptChars`): with word timing the highlight crosses each word during that word and rests between words; lines without word timing sweep linearly from the line start to its end (the next lead line's start when it has none), capped at 10 s. `SweepText` (`widgets/ruby_lyric_line.dart`) draws the line twice and clips the highlight layer to the boxes of the sung characters; the clip listens to one `ValueNotifier` updated by the lyric ticker, so a frame repaints one line. The sweep can be turned off (the active line is then one colour). Accuracy target ±30 ms against the engine clock: `kalao-audio` renders a click track and compares the reported position with the click in the output (tempo 1 and 0.5); `lyrics_test.dart` models 30 Hz position reports and checks when lines turn active; `integration_test/lyrics_timing_test.dart` repeats it on a device.

**Sync editor (2.9).** `controllers/lyrics_sync_editor_controller.dart` (`LyricsSyncEditor`: the draft, taps, nudge, undo; no Flutter widgets) + `screens/lyrics_sync_screen.dart` (route `/player/sync`, opened from the lyrics options sheet). As built: a tap stamps the start of the cursor's line or word; a tap held ≥ 350 ms also stamps the end at release; words are one per CJK character and one per whitespace-separated word otherwise (`splitWords`, punctuation stays with its neighbour); the tap position is the interpolated engine position minus the tap-latency setting (0–200 ms, default 40) scaled by the tempo, and the engine position already subtracts output latency; speeds 50/75/100% through `playerSetTempo` (reset to 100% on leaving); nudge ±10/±50 ms moves the last stamped word or line (or a line selected by tapping it, which also moves the cursor there to re-time from it); an existing timed document opens with its timing and offset applied. Save writes a new version (`source_kind = userEdited`, offset 0, annotation layers carried over, word timing kept for lines whose every word was stamped). The original plan was an editor screen built from Mornye `lyrics_editor_sheet.dart` and `utils/lyrics_draft.dart`:
- *Line mode:* play; tap the big button at each line start; the release time of the hold is the line end (optional).
- *Word mode:* per line, tap for each word (Chinese/Japanese split per character or per jieba/lindera token).
- Tempo can be lowered to 50% while timing; taps are converted back to song time. Timestamps are corrected for touch latency (configurable, default 40 ms) and output latency.
- Nudge controls (±10/50 ms), replay-line, undo. Saved as a new `lyric_doc` version with `source = userEdited`; export to LRC/eLRC.

## 5. Modes (3.1, 3.2)

- **Learn mode** (default for songs in a language other than the UI language): original vocals; all annotation layers available; translation; loop current line; A–B repeat (long-press two lines); slow-down presets 50/75/90%; line stepping with ↑/↓ and tap.
- **OG Karaoke mode:** instrumental (or vocals at the user's guide level); lyrics in large type, two lines visible, word sweep; countdown dots for gaps ≥ 4 s before the next line (Mornye's `lyric_gap_indicator.dart`), including the intro; next singer from the queue shown at the end; mic monitoring and scoring when enabled (M7). Screen kept awake (Mornye `lyrics_screen_awake.dart`).
- Mode is a per-play choice on the now-playing screen; the last choice per song is remembered.
- As built (M3): `PlayerController` holds the mode (`setMode` switches the track and stores `song.last_mode`); a song opens in the mode last used for it, else Learn. Learn tools sit in the player controls (repeat-line toggle, speed chips; long-press a line, then another, for A–B). Karaoke uses `KaraokeLyricsView` for timed lyrics (`KaraokeFrame.at` decides the current line, the next line and the countdown) and falls back to the scrolling view for untimed ones. The countdown and keep-screen-on can be turned off in the lyrics options.

## 6. Queue (6.5) and favorites (6.3)

Mornye's queue model (`library_queue_store.dart`, `app_state_database.dart`, `queue_tab*`) with Kalao fields: `singer` (free text name, parties use the guest name) and `mode`. As built (M3.4): `QueueStore` over `queue_item` in `kalao_app_state.db`, `queueProvider`/`QueueActions`, and `PlayerController.playNextInQueue`, which runs when the engine reports a song completed and skips entries whose song was deleted. Favorites use Mornye's loved-tracks pattern on `song.id`.

## 7. Stats (6.7)

As built (M4.2): `HistoryDatabase.stats` aggregates in SQLite (no data job is needed: `GROUP BY` over the indexed `play` table is fast) and `stats_screen.dart` shows it. Planned from Mornye `listening_statistics.dart`, over Kalao's `play` history rows (`song_id`, `started_at`, `duration_ms`, `mode`, `score`, `singer`): totals per day/week, top songs, most-practised (learn mode time), best scores. Aggregation is a `statsAggregate` data job for large histories.

## 8. Stems

See STEM_SEPARATION.md. Engine-facing details: stems are FLAC files `stems/<sha256>/{vocals,instrumental}.flac` at 44.1 kHz stereo; `playerLoad` receives them as `vocals` + `instrumental` sources. The job runs inside Mornye's `BackgroundWorkService` with kind `stems` (foreground type `dataSync`), notification text supplied by Dart, progress on `stem_progress_stream`.

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

Mornye's split: Dart `backup_service.dart` decides what goes in and merges what comes out (`backup_screen.dart` drives it, `BackupController` runs one job at a time inside `BackgroundWorkService` kind `backup`); Rust `kalao-mobile::native_backup` streams files into and out of the ZIP in the `backupWrite` / `backupInspect` data jobs, so media never passes through the UI isolate.
- As built (M4): snapshots are `VACUUM INTO` copies of the live databases; covers always go in, imported audio when the user includes it. `backupInspect` checks every name (relative, plain characters, no `..`), the entry count, the expansion ratio, the declared size and the SHA-256 of every entry and the format before anything is kept, and extracts into `backup_work/`. Dart then runs `PRAGMA integrity_check`, refuses a newer schema and migrates an older one on the copy, and builds the preview. Merge and Replace run in Dart with the backup database `ATTACH`ed to the live connection, in one transaction per database, so there is no `backupRestore` job and no database swap; absolute file paths are rewritten to this device's folders.
- Archive: `.kalaobackup` = ZIP with `manifest.json` (format version, app version, created_at, categories, counts, per-entry SHA-256), `library.db`, `history.db`, `app_state.db` (SQLite online-backup snapshots), `settings.json` (non-secret preferences), `extensions/*.kalaoext` + `extensions.json` (enabled, priority, repos), optional `media/` and `stems/`.
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

Mornye `update_checker.dart` + `apk_downloader.dart`: once a day if enabled, read `api.github.com/repos/kalaoapp/Kalao/releases/latest`, compare versions, pick the APK for the device ABI (arm64 / arm32 / universal), and show `update_dialog.dart` with the changelog. Only when the user taps Update: download to cache with a progress notification, verify the SHA-256 from the release's checksums file, then hand the APK to the package installer (`installApk`, `REQUEST_INSTALL_PACKAGES`). "Open release page" is always offered.
- As built (M4.11): `UpdateService` (`http`) and `UpdateController`; the device ABIs come from Kotlin (`getSupportedAbis`); assets are named `Kalao-<version>-{arm64,arm32,x86_64,universal}.apk` as `release.yml` publishes them. The APK is downloaded to `cache/updates/` and hashed with the Rust `hash_file` job; `installApk` only accepts a file from that folder and shares it through a `FileProvider`. Without the "install unknown apps" permission it opens that setting instead. Old downloads are removed at the next check. The last check time is in shared_preferences (`update_checked_at`).

## 15. Diagnostics (9.5)

Mornye logging: Dart `AppLogger` + Rust `LogBuffer` (ring buffer, secrets redacted by `redact`), merged in `log_screen.dart`; shared as a text file through the share sheet (`share_plus`, M4.8). `app_crash_service.dart` and `AppCrashReporter.kt` keep the last crash report locally and show `app_crash_banner.dart` on next start with "Copy" and "Open GitHub issue" (pre-filled template, nothing sent automatically).

## 16. Settings

`models/settings.dart` (`json_serializable`, Mornye pattern) groups: appearance (theme mode, dynamic color, seed, lyric size, font), lyrics (layers on/off per language, Chinese variant, offset step, auto-fetch, provider priority), playback (default mode, crossfade on switch, countdown, keep screen on), stems (processing local/remote, model, battery/thermal pause, remote server URL), translation (target language, MyMemory email), mic (latency per route, monitoring gain/reverb), backup (folder URI, schedule, keep N, include media), updates (check enabled), party (room name, require approval), developer (extension developer mode). Searchable through Mornye `settings_search_catalog.dart`.

## 17. Testing

- **Rust:** unit tests per crate; fixtures for annotate (POC cases), LRC/eLRC/TTML round trips, matching, MyMemory response parsing, backup archive round trip, party pairing proofs; audio engine tests on rendered buffers (sync of stems = sample-identical sums, crossfade gain curve, loop seam, stretcher bypass).
- **Kotlin:** `MainActivityRoutingTest` (Mornye) and SAF/IO unit tests.
- **Dart:** unit and widget tests (`flutter test`) for services, providers and lyric layout; golden tests for ruby layout in four languages.
- **Integration (`integration_test/`, Mornye style):** lyric timing accuracy (±30 ms; `lyrics_timing_test.dart`, added in M2, run with `fvm flutter test integration_test` on a device); later: playback start/stop and session restore, import pairing, backup round trip on device, stems job resume after process kill, party with two emulators.
- **CI:** Mornye's `ci.yml` jobs adapted (ROADMAP M0).
