// Table layout follows Mornye's library_schema.dart pattern (Dart owns the
// schema and migrations); tables are Kalao's (DATA_MODEL.md §2).

/// `kalao_library.db`. Bump [libraryVersion] and add a step to
/// [libraryMigrations] for every change; never edit a released step.
const libraryVersion = 2;

const libraryMigrations = <int, List<String>>{
  1: [
    '''
CREATE TABLE song (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  language TEXT,
  duration_ms INTEGER,
  isrc TEXT,
  cover_path TEXT,
  origin TEXT NOT NULL DEFAULT 'local',
  ext_ref TEXT,
  song_key TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  last_mode TEXT
)''',
    'CREATE INDEX song_key_idx ON song(song_key)',
    'CREATE INDEX song_added_idx ON song(added_at)',
    '''
CREATE TABLE media_file (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id INTEGER NOT NULL REFERENCES song(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  bytes INTEGER NOT NULL DEFAULT 0,
  codec TEXT NOT NULL DEFAULT '',
  sample_rate INTEGER,
  source TEXT NOT NULL DEFAULT 'import',
  pinned INTEGER NOT NULL DEFAULT 0,
  UNIQUE(song_id, kind)
)''',
    'CREATE INDEX media_sha_idx ON media_file(sha256)',
    '''
CREATE TABLE lyric_doc (
  song_id INTEGER NOT NULL REFERENCES song(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  json TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(song_id, version)
)''',
    '''
CREATE TABLE lyric_annotation (
  song_id INTEGER NOT NULL REFERENCES song(id) ON DELETE CASCADE,
  doc_version INTEGER NOT NULL,
  line_index INTEGER NOT NULL,
  kind TEXT NOT NULL,
  json TEXT NOT NULL,
  origin TEXT NOT NULL,
  PRIMARY KEY(song_id, doc_version, line_index, kind)
)''',
    '''
CREATE TABLE song_search (
  song_id INTEGER NOT NULL REFERENCES song(id) ON DELETE CASCADE,
  key_kind TEXT NOT NULL,
  key TEXT NOT NULL
)''',
    'CREATE INDEX song_search_song_idx ON song_search(song_id)',
  ],
  // M4.1 favorites, M4.5 the scheduled-backup log.
  2: [
    '''
CREATE TABLE favorite (
  song_id INTEGER PRIMARY KEY REFERENCES song(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL
)''',
    '''
CREATE TABLE backup_run (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  target TEXT NOT NULL DEFAULT '',
  bytes INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error TEXT
)''',
  ],
};

/// `kalao_history.db`.
const historyVersion = 1;

const historyMigrations = <int, List<String>>{
  1: [
    '''
CREATE TABLE play (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id INTEGER NOT NULL,
  song_key TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  mode TEXT NOT NULL,
  score REAL,
  line_scores_json TEXT,
  singer TEXT,
  party INTEGER NOT NULL DEFAULT 0
)''',
    'CREATE INDEX play_started_idx ON play(started_at)',
    'CREATE INDEX play_song_idx ON play(song_id)',
  ],
};

/// `kalao_app_state.db`.
const appStateVersion = 2;

const appStateMigrations = <int, List<String>>{
  1: [
    'CREATE TABLE playback_session (key TEXT PRIMARY KEY, value TEXT)',
    '''
CREATE TABLE recent_access (
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  accessed_at INTEGER NOT NULL,
  PRIMARY KEY(kind, ref)
)''',
  ],
  // M3.4: the singing queue.
  2: [
    '''
CREATE TABLE queue_item (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id INTEGER NOT NULL,
  position INTEGER NOT NULL,
  singer TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT 'karaoke',
  added_by TEXT NOT NULL DEFAULT 'host'
)''',
    'CREATE INDEX queue_position_idx ON queue_item(position)',
  ],
};
