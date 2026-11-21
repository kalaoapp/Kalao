import 'dart:convert';

import 'package:kalao/models/extension.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:kalao/services/library_search.dart';
import 'package:sqflite/sqflite.dart';

/// Opens [path] with [migrations] applied in order (Mornye's pattern: Dart
/// owns schemas; Rust jobs only ever see detached copies).
Future<Database> openVersionedDatabase(
  String path, {
  required int version,
  required Map<int, List<String>> migrations,
  DatabaseFactory? factory,
}) {
  Future<void> migrate(Database db, int from, int to) async {
    for (var step = from + 1; step <= to; step++) {
      for (final statement in migrations[step] ?? const <String>[]) {
        await db.execute(statement);
      }
    }
  }

  return (factory ?? databaseFactory).openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, to) => migrate(db, 0, to),
      onUpgrade: migrate,
    ),
  );
}

enum SongSort { recentlyAdded, title, artist }

/// Everything a new song needs; files are already in app storage.
class NewSong {
  const NewSong({
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationMs,
    this.isrc,
    this.coverPath,
    required this.media,
    this.language,
    this.extRef,
  });

  final String title;
  final String artist;
  final String album;
  final int? durationMs;
  final String? isrc;
  final String? coverPath;
  final List<NewMediaFile> media;
  final String? language;

  /// For a song added from an extension (`origin = extension`).
  final ExtensionTrackRef? extRef;
}

class NewMediaFile {
  const NewMediaFile({
    required this.kind,
    required this.path,
    required this.sha256,
    this.bytes = 0,
    this.codec = '',
    this.sampleRate,
    this.source = 'import',
  });

  final MediaKind kind;
  final String path;
  final String sha256;
  final int bytes;
  final String codec;
  final int? sampleRate;

  /// `media_file.source`: `import`, `extension` for offline downloads, or
  /// `folder` for a music-folder file played in place (FEATURES 6.8).
  final String source;
}

/// `kalao_library.db`: songs, media files, lyric documents and layers,
/// search keys.
class LibraryDatabase {
  LibraryDatabase(this.db);

  final Database db;

  /// Lyric document versions kept per song for undo.
  static const keptLyricVersions = 5;

  static Future<LibraryDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async => LibraryDatabase(
    await openVersionedDatabase(
      path,
      version: libraryVersion,
      migrations: libraryMigrations,
      factory: factory,
    ),
  );

  Future<void> close() => db.close();

  /// ISRC, or normalised title + artist + duration rounded to 5 s, so the
  /// same song matches across backups and devices.
  static String songKey(
    String title,
    String artist,
    int? durationMs,
    String? isrc,
  ) {
    if (isrc != null && isrc.trim().isNotEmpty) {
      return 'isrc:${isrc.trim().toUpperCase()}';
    }
    final rounded = durationMs == null ? '' : '${(durationMs / 5000).round()}';
    return 'tad:${normalizeSearchText(title)}|${normalizeSearchText(artist)}|$rounded';
  }

  Future<int> insertSong(NewSong song, {DateTime? now}) => db.transaction((
    txn,
  ) async {
    final id = await txn.insert('song', {
      'title': song.title,
      'artist': song.artist,
      'album': song.album,
      'duration_ms': song.durationMs,
      'isrc': song.isrc,
      'cover_path': song.coverPath,
      'language': song.language,
      'origin': song.extRef == null ? 'local' : 'extension',
      'ext_ref': song.extRef == null ? null : jsonEncode(song.extRef!.toJson()),
      'song_key': songKey(song.title, song.artist, song.durationMs, song.isrc),
      'added_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    });
    for (final file in song.media) {
      await _insertMedia(txn, id, file);
    }
    return id;
  });

  Future<void> setMedia(int songId, NewMediaFile file) =>
      _insertMedia(db, songId, file);

  Future<void> removeMedia(int songId, MediaKind kind) => db.delete(
    'media_file',
    where: 'song_id = ? AND kind = ?',
    whereArgs: [songId, kind.name],
  );

  /// Records what a changed file now holds (a music-folder file edited in
  /// place keeps its path).
  Future<void> updateMediaDetails(
    int songId,
    MediaKind kind, {
    required int bytes,
    required String codec,
    int? sampleRate,
  }) => db.update(
    'media_file',
    {'bytes': bytes, 'codec': codec, 'sample_rate': sampleRate},
    where: 'song_id = ? AND kind = ?',
    whereArgs: [songId, kind.name],
  );

  Future<void> _insertMedia(
    DatabaseExecutor executor,
    int songId,
    NewMediaFile file,
  ) => executor.insert('media_file', {
    'song_id': songId,
    'kind': file.kind.name,
    'path': file.path,
    'sha256': file.sha256,
    'bytes': file.bytes,
    'codec': file.codec,
    'sample_rate': file.sampleRate,
    'source': file.source,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Applies details from a metadata extension (FEATURES 6.4); null
  /// arguments keep what the song has. The song key is recomputed.
  Future<void> updateDetails(
    int songId, {
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? isrc,
    String? language,
    String? coverPath,
  }) => db.transaction((txn) async {
    final rows = await txn.query('song', where: 'id = ?', whereArgs: [songId]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final next = {
      'title': title ?? row['title'],
      'artist': artist ?? row['artist'],
      'album': album ?? row['album'],
      'duration_ms': durationMs ?? row['duration_ms'],
      'isrc': isrc ?? row['isrc'],
      'language': language ?? row['language'],
      'cover_path': coverPath ?? row['cover_path'],
    };
    await txn.update(
      'song',
      {
        ...next,
        'song_key': songKey(
          next['title']! as String,
          next['artist'] as String? ?? '',
          next['duration_ms'] as int?,
          next['isrc'] as String?,
        ),
      },
      where: 'id = ?',
      whereArgs: [songId],
    );
  });

  /// An extension song already in the library ([ref]'s extension and
  /// track), if any.
  Future<int?> songIdForTrack(ExtensionTrackRef ref) async {
    final rows = await db.query(
      'song',
      columns: ['id', 'ext_ref'],
      where: "origin = 'extension'",
    );
    for (final row in rows) {
      final other = Song.parseExtRef(row['ext_ref'] as String?);
      if (other?.extensionId == ref.extensionId &&
          other?.trackId == ref.trackId) {
        return row['id'] as int;
      }
    }
    return null;
  }

  Future<List<Song>> songs({
    SongSort sort = SongSort.recentlyAdded,
    int? limit,
    bool favoritesOnly = false,
  }) async {
    final order = switch (sort) {
      SongSort.recentlyAdded => 'added_at DESC, id DESC',
      SongSort.title => 'title COLLATE NOCASE, id',
      SongSort.artist => 'artist COLLATE NOCASE, title COLLATE NOCASE, id',
    };
    final rows = await db.query(
      'song',
      where: favoritesOnly ? 'id IN (SELECT song_id FROM favorite)' : null,
      orderBy: order,
      limit: limit,
    );
    return _withMedia(rows);
  }

  // Favorites (Mornye's loved-tracks pattern on `song.id`)

  Future<void> setFavorite(int songId, bool favorite, {DateTime? now}) =>
      favorite
      ? db.insert('favorite', {
          'song_id': songId,
          'created_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore)
      : db.delete('favorite', where: 'song_id = ?', whereArgs: [songId]);

  Future<bool> isFavorite(int songId) async => (await db.query(
    'favorite',
    where: 'song_id = ?',
    whereArgs: [songId],
  )).isNotEmpty;

  Future<List<Song>> songsByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await db.query(
      'song',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    final byId = {for (final song in await _withMedia(rows)) song.id: song};
    return [for (final id in ids) ?byId[id]];
  }

  Future<Song?> song(int id) async => (await songsByIds([id])).firstOrNull;

  /// The song that already has a file with [sha256], for duplicate detection.
  Future<int?> songIdForSha(String sha256) async {
    final rows = await db.query(
      'media_file',
      columns: ['song_id'],
      where: 'sha256 = ?',
      whereArgs: [sha256],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['song_id'] as int;
  }

  /// Which of [shas] some song still uses (before deleting their files).
  Future<Set<String>> usedShas(Iterable<String> shas) async {
    final distinct = shas.toSet().toList();
    if (distinct.isEmpty) return const {};
    final rows = await db.query(
      'media_file',
      distinct: true,
      columns: ['sha256'],
      where: 'sha256 IN (${List.filled(distinct.length, '?').join(',')})',
      whereArgs: distinct,
    );
    return {for (final row in rows) row['sha256']! as String};
  }

  Future<void> deleteSongs(List<int> ids) async {
    if (ids.isEmpty) return;
    await db.delete(
      'song',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<void> setLastMode(int songId, String mode) => db.update(
    'song',
    {'last_mode': mode},
    where: 'id = ?',
    whereArgs: [songId],
  );

  Future<List<Song>> _withMedia(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const [];
    final ids = [for (final row in rows) row['id'] as int];
    final marks = List.filled(ids.length, '?').join(',');
    final media = await db.query(
      'media_file',
      where: 'song_id IN ($marks)',
      whereArgs: ids,
    );
    final lyrics = await db.rawQuery(
      'SELECT DISTINCT song_id FROM lyric_doc WHERE song_id IN ($marks)',
      ids,
    );
    final withLyrics = {for (final row in lyrics) row['song_id'] as int};
    final favorites = {
      for (final row in await db.rawQuery(
        'SELECT song_id FROM favorite WHERE song_id IN ($marks)',
        ids,
      ))
        row['song_id'] as int,
    };
    final files = <int, List<MediaFile>>{};
    for (final row in media) {
      final kind = MediaKind.values.asNameMap()[row['kind']];
      if (kind == null) continue;
      (files[row['song_id'] as int] ??= []).add(
        MediaFile(
          kind: kind,
          path: row['path'] as String,
          sha256: row['sha256'] as String,
          codec: row['codec'] as String? ?? '',
        ),
      );
    }
    return [
      for (final row in rows)
        Song(
          id: row['id'] as int,
          title: row['title'] as String,
          artist: row['artist'] as String? ?? '',
          album: row['album'] as String? ?? '',
          durationMs: row['duration_ms'] as int?,
          coverPath: row['cover_path'] as String?,
          addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
          lastMode: row['last_mode'] as String?,
          media: files[row['id']] ?? const [],
          hasLyrics: withLyrics.contains(row['id']),
          favorite: favorites.contains(row['id']),
          songKey: row['song_key'] as String? ?? '',
          isrc: row['isrc'] as String?,
          language: row['language'] as String?,
          extRef: Song.parseExtRef(row['ext_ref'] as String?),
        ),
    ];
  }

  // Lyrics

  /// Saves [doc] as a new version with its [layers] (per line index) and
  /// keeps the last [keptLyricVersions]. Returns the version.
  Future<int> saveLyrics(
    int songId,
    LyricDocument doc, {
    required String sourceKind,
    Map<int, Map<LyricLayerKind, LyricLayer>> layers = const {},
    DateTime? now,
  }) => db.transaction((txn) async {
    final latest = Sqflite.firstIntValue(
      await txn.rawQuery(
        'SELECT MAX(version) FROM lyric_doc WHERE song_id = ?',
        [songId],
      ),
    );
    final version = (latest ?? 0) + 1;
    await txn.insert('lyric_doc', {
      'song_id': songId,
      'version': version,
      'json': jsonEncode(doc.toJson()),
      'source_kind': sourceKind,
      'updated_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    });
    for (final MapEntry(key: lineIndex, value: lineLayers) in layers.entries) {
      for (final MapEntry(key: kind, value: layer) in lineLayers.entries) {
        await txn.insert('lyric_annotation', {
          'song_id': songId,
          'doc_version': version,
          'line_index': lineIndex,
          'kind': kind.name,
          'json': jsonEncode([for (final s in layer.segments) s.toJson()]),
          'origin': layer.origin.name,
        });
      }
    }
    await pruneLyricVersions(txn, songId, version);
    return version;
  });

  /// Drops versions older than the last [keptLyricVersions] before
  /// [latest].
  static Future<void> pruneLyricVersions(
    DatabaseExecutor executor,
    int songId,
    int latest,
  ) async {
    final stale = latest - keptLyricVersions;
    if (stale <= 0) return;
    await executor.delete(
      'lyric_doc',
      where: 'song_id = ? AND version <= ?',
      whereArgs: [songId, stale],
    );
    await executor.delete(
      'lyric_annotation',
      where: 'song_id = ? AND doc_version <= ?',
      whereArgs: [songId, stale],
    );
  }

  /// Changes the per-song offset of the current version in place (an offset
  /// tweak is not a new version).
  Future<void> setLyricsOffset(int songId, int offsetMs) =>
      db.transaction((txn) async {
        final docs = await txn.query(
          'lyric_doc',
          where: 'song_id = ?',
          whereArgs: [songId],
          orderBy: 'version DESC',
          limit: 1,
        );
        if (docs.isEmpty) return;
        final json = (jsonDecode(docs.first['json'] as String) as Map)
            .cast<String, dynamic>();
        await txn.update(
          'lyric_doc',
          {
            'json': jsonEncode({...json, 'offsetMs': offsetMs}),
          },
          where: 'song_id = ? AND version = ?',
          whereArgs: [songId, docs.first['version']],
        );
      });

  /// `source_kind` of the current lyric document (`file`, `embedded`,
  /// `extension`, an edit…), or null when the song has none.
  Future<String?> lyricsSourceKind(int songId) async {
    final rows = await db.query(
      'lyric_doc',
      columns: ['source_kind'],
      where: 'song_id = ?',
      whereArgs: [songId],
      orderBy: 'version DESC',
      limit: 1,
    );
    return rows.firstOrNull?['source_kind'] as String?;
  }

  /// The current lyric document with its layers merged into the lines.
  Future<LyricDocument?> lyrics(int songId) async {
    final docs = await db.query(
      'lyric_doc',
      where: 'song_id = ?',
      whereArgs: [songId],
      orderBy: 'version DESC',
      limit: 1,
    );
    if (docs.isEmpty) return null;
    final version = docs.first['version'] as int;
    final doc = LyricDocument.fromJson(
      (jsonDecode(docs.first['json'] as String) as Map).cast<String, dynamic>(),
    );
    final annotations = await db.query(
      'lyric_annotation',
      where: 'song_id = ? AND doc_version = ?',
      whereArgs: [songId, version],
    );
    final lines = [...doc.lines];
    for (final row in annotations) {
      final index = row['line_index'] as int;
      final kind = LyricLayerKind.values.asNameMap()[row['kind']];
      if (kind == null || index >= lines.length) continue;
      final segments = [
        for (final segment in jsonDecode(row['json'] as String) as List)
          RubySegment.fromJson((segment as Map).cast<String, dynamic>()),
      ];
      lines[index] = lines[index].withLayer(
        kind,
        LyricLayer(
          segments: segments,
          origin:
              LayerOrigin.values.asNameMap()[row['origin']] ?? LayerOrigin.auto,
        ),
      );
    }
    return doc.withLines(lines);
  }

  // Search

  Future<void> replaceSearchKeys(
    List<int> songIds,
    List<Map<String, dynamic>> rows,
  ) => db.transaction((txn) async {
    if (songIds.isNotEmpty) {
      await txn.delete(
        'song_search',
        where: 'song_id IN (${List.filled(songIds.length, '?').join(',')})',
        whereArgs: songIds,
      );
    }
    final batch = txn.batch();
    for (final row in rows) {
      batch.insert('song_search', {
        'song_id': row['songId'],
        'key_kind': row['keyKind'],
        'key': row['key'],
      });
    }
    await batch.commit(noResult: true);
  });

  /// Songs whose title, artist, pinyin, initials or romaji key contains the
  /// normalised [query], best matches first (prefix before substring).
  Future<List<Song>> search(String query, {int limit = 100}) async {
    final key = normalizeSearchText(query);
    if (key.isEmpty) return const [];
    final escaped = key
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = await db.rawQuery(
      '''
SELECT song_id, MIN(CASE WHEN key LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END) AS rank
FROM song_search
WHERE key LIKE ? ESCAPE '\\'
GROUP BY song_id
ORDER BY rank, song_id DESC
LIMIT ?''',
      ['$escaped%', '%$escaped%', limit],
    );
    return songsByIds([for (final row in rows) row['song_id'] as int]);
  }

  /// `{id, title, artist}` for every song, for the `rebuildSearchKeys` job.
  Future<List<Map<String, Object?>>> searchSources([List<int>? ids]) =>
      db.query(
        'song',
        columns: ['id', 'title', 'artist'],
        where: ids == null
            ? null
            : 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids,
      );
}
