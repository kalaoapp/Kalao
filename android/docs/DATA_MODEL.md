# Data Model

Ownership follows Mornye (ARCHITECTURE.md §6): Dart owns the schemas and migrations (`sqflite`, all in `services/library_schema.dart`), Rust never opens the live databases, settings live in `shared_preferences`, secrets (from M5) in `flutter_secure_storage`.

## 1. Timed lyrics

The POC stored text layers only, with no timing. Kalao separates **text and timing** (the lyric document) from **annotations** (generated or edited layers). In memory, Dart uses `LyricDocument` / `LyricLine` (`models/lyrics.dart`, IMPLEMENTATION.md §4). Rust exchanges the same shape as JSON:

```json
{
  "version": 2,
  "format": "elrc",
  "sourceLang": "zh",
  "timed": true,
  "offsetMs": 0,
  "lines": [
    { "timeMs": 12340, "endMs": 15800, "text": "月亮代表我的心",
      "section": "chorus", "sectionBreakBefore": true,
      "words": [ { "timeMs": 12340, "endMs": 12900, "text": "月", "start": 0 } ],
      "voice": "v1", "translation": "The moon represents my heart" }
  ]
}
```

`version` 2 (M2) added `words`, `voice` and `translation`; version 1 documents read unchanged. `format` is how the text arrived (`plain`, `lrc`, `elrc`, `ttml`). `offsetMs` is added to the playback position before the line lookup (positive = lyrics earlier, as LRC's `[offset:]`). `words` are in text order; `start` is the word's UTF-16 offset in `text`, set by `parseLyrics` (documents saved before it find the words in `text` in order); `endMs` is optional on lines and words (a line ends when the next lead line starts, a word when the next word starts). `voice` is `v1`, `v2`, … in a duet and `bg` for backing vocals; `words`, `voice`, `translation` and `section` are omitted when empty. A `source` object (extension id and item) is added with lyric extensions in M5.

Annotation layers per line:

```json
{ "lineIndex": 0, "kind": "pinyin", "origin": "auto",
  "segments": [ { "start": 0, "end": 1, "reading": "yuè" }, { "start": 1, "end": 2, "reading": "liang" } ] }
```

`kind` ∈ `pinyin`, `furigana`, `romaji`, `translation:<lang>` (`traditional`/`simplified` are not stored: the Chinese variant is applied for display, IMPLEMENTATION.md §4); `origin` ∈ `auto`, `human`, `translator`. `human` layers are never overwritten by regeneration. Enhanced LRC round-trips through `core::lyrics::doc` without loss of line or word timing, sections, breaks or voices; plain LRC keeps line starts.

## 2. Local databases (Dart-owned, sqflite)

### `kalao_library.db` (`services/library_schema.dart`)

| Table | Main columns | Notes |
| --- | --- | --- |
| `song` | id, title, artist, album, language, duration_ms, isrc, cover_path, origin (`local`/`extension`), ext_ref, song_key, added_at, last_mode | `song_key` = ISRC, or normalised title + artist + rounded duration; matches songs across backups |
| `media_file` | id, song_id, kind (`original`/`instrumental`/`vocals`), path, sha256, bytes, codec, sample_rate, source (`import`/`extension`/`stems_local`/`stems_remote`), pinned | Imported files live in `media/<sha256>.<ext>`, stems in `stems/<sha256>/` |
| `lyric_doc` | song_id, version, json, source_kind, updated_at | Latest version is current; older versions kept (last 5) for undo |
| `lyric_annotation` | song_id, doc_version, line_index, kind, json, origin | |
| `song_search` | song_id, key_kind (`title`/`artist`/`pinyin`/`initials`/`romaji`), key | Rebuilt by the `rebuildSearchKeys` job |
| `favorite` | song_id, created_at | Library v2 |
| `backup_run` | id, started_at, finished_at, target (`folder`/`file`), bytes, status, error | Library v2; backup log |
| `melody` *(planned, M7)* | sha256, path, frames, created_at | Reference pitch track for scoring |
| `stem_job` *(planned, M6)* | id, song_id, sha256, mode (`local`/`remote`), model, status, progress, remote_job_id, error, created_at | Mirror of Rust job state for UI; checkpoints are Rust files |

`language`, `origin`, `ext_ref` and `media_file.pinned` exist for extensions and stems but are not written yet.

### `kalao_history.db` (`services/library_schema.dart`, `history_database.dart`)

| Table | Main columns |
| --- | --- |
| `play` | id, song_id, song_key, started_at, duration_ms, mode (`learn`/`karaoke`/`listen`), score, line_scores_json, singer, party (bool) |

### `kalao_app_state.db` (`services/library_schema.dart`, `AppStateDatabase` in `history_database.dart`)

| Table | Main columns |
| --- | --- |
| `queue_item` | id, song_id, position, singer, mode, added_by (`host`/guest id) — app state v2 |
| `playback_session` | key, value (session restore for "Continue singing": song, position, vocal level) |
| `recent_access` | kind, ref, accessed_at |

### Files and other stores

| Store | Owner | Contents |
| --- | --- | --- |
| `shared_preferences` | `settings_provider` | `AppSettings` JSON (IMPLEMENTATION.md §16), `update_checked_at`; later the daily MyMemory character counter |
| `media/`, `covers/` | `import_service.dart` | Imported audio as `<sha256>.<ext>`, embedded cover art |
| `backups/`, `backup_work/` | `backup_service.dart` | Safety backups before a Replace (newest three), scratch space for export and restore |
| `flutter_secure_storage` *(M5–M6)* | Dart | Stem API key, install ID, MyMemory contact email, extension `secret` settings |
| `extensions/` *(M5)* | `kalao-extensions` | Installed packages, per-extension key-value storage and cookies |
| `models/` *(M6)* | `kalao-stems` | User-installed ONNX models (verified by SHA-256), plus partial downloads |
| `stems/<sha256>/` *(M6)* | `kalao-stems` | `vocals.flac`, `instrumental.flac`, `job.json` checkpoints |
| `melody/<sha256>.bin` *(M7)* | `kalao-audio` | Pitch frames (u16 cents per 10 ms) |
| `translations/` *(M6)* | Dart translation service | Translation cache, keyed by line-list hash + language pair |
| `recordings/` *(M8)* | `kalao-audio` | User-started FLAC recordings |

## 3. Backup file (`.kalaobackup`)

A ZIP written and read by `kalao-mobile::native_backup` in the `backupWrite` / `backupInspect` data jobs, with contents and restore decided by Dart `backup_service.dart`:

```
kalao-2026-11-15-2105.kalaobackup
├── manifest.json        # format, app, appVersion, createdAt, categories, counts, secrets: false, sha256 + bytes per entry
├── library.db           # VACUUM INTO snapshot
├── history.db
├── app_state.db
├── settings.json        # AppSettings without secrets
├── covers/              # cover art, by file name
├── media/               # optional: imported audio, by sha256
├── extensions.json      # (M5) ids, versions, enabled, priority, repositories
├── extensions/*.kalaoext # (M5)
└── stems/               # (M6) optional: stems, by sha256
```

- `format` (now 1) is an integer bumped on breaking changes. A newer app migrates every older format; an older app refuses a newer one with a clear message. Each database also carries its schema version (`PRAGMA user_version`), migrated on the extracted copy.
- Restore verifies every checksum first. **Merge:** songs matched by `song_key`, media by sha256, the backup's lyrics win when their `updated_at` is newer, this library's `human` layers are kept on unchanged lines, favorites and plays are unioned (plays de-duplicated by `started_at` + `song_key`). **Replace:** a safety backup of the current data is written to `backups/`, then every table except `backup_run` is replaced from the backup in one transaction per database, and the backup's settings are applied except this device's own keys.
- Never included: secrets, translation cache, stem models, melody cache, logs.
- Backups are not encrypted; the export screen says so. They contain no credentials.

## 4. Stem server Postgres (`stem-server/`)

| Table | Columns |
| --- | --- |
| `api_keys` | id, prefix, hash (argon2), note, device_hash, bound_at, revoked_at, created_at |
| `jobs` | id, key_id, status, model, input_bytes, duration_ms, created_at, finished_at, error |
| `usage_daily` | key_id, day, jobs, audio_seconds |
