// Backup layout and restore follow Mornye's split (Dart decides categories
// and merges; Rust streams the archive), with Kalao's format (DATA_MODEL.md
// §3, IMPLEMENTATION.md §12).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:kalao/services/extension_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const _log = AppLogger('Backup');

/// A backup or restore failed with a message for the user.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum RestoreMode {
  /// Songs matched by `song_key`, media by SHA-256, newer lyrics win,
  /// `human` layers kept, favorites and plays unioned.
  merge,

  /// The current data is saved to a safety backup, then swapped.
  replace,
}

/// What a backup holds, for the preview before restoring.
@immutable
class BackupPreview {
  const BackupPreview({
    required this.createdAt,
    required this.appVersion,
    required this.songs,
    required this.newSongs,
    required this.plays,
    required this.favorites,
    required this.withLyrics,
    required this.mediaFiles,
    required this.missingMedia,
    required this.bytes,
  });

  final DateTime? createdAt;
  final String appVersion;
  final int songs;

  /// Songs whose `song_key` is not in the library yet (what Merge adds).
  final int newSongs;
  final int plays;
  final int favorites;
  final int withLyrics;

  /// Audio files in the backup (0 when it was made without media).
  final int mediaFiles;

  /// Songs whose audio is neither in the backup nor on this device: they are
  /// restored but cannot play until their audio is imported again.
  final int missingMedia;
  final int bytes;
}

/// An extracted, checked backup waiting for the user's choice.
class StagedBackup {
  StagedBackup._(this.dir, this.manifest, this.preview);

  final Directory dir;
  final Map<String, dynamic> manifest;
  final BackupPreview preview;

  String get libraryDb => p.join(dir.path, 'library.db');
  String get historyDb => p.join(dir.path, 'history.db');
  String get appStateDb => p.join(dir.path, 'app_state.db');
  File get settings => File(p.join(dir.path, 'settings.json'));
}

/// `.kalaobackup` export, inspection and restore (FEATURES 7.1–7.3, 7.5).
/// Secrets live in secure storage and are never read here.
class BackupService {
  BackupService(this.services, {DatabaseFactory? factory, this.extensions})
    : _factory = factory ?? databaseFactory;

  /// Installed extensions and repositories go into backups when set
  /// (DATA_MODEL.md §3); their secrets never do.
  final ExtensionService? extensions;

  /// Bumped on breaking changes; older formats are always readable.
  static const format = 1;

  final LibraryServices services;
  final DatabaseFactory _factory;

  /// `kalao-2026-11-17-2105.kalaobackup`.
  static String fileName(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'kalao-${at.year}-${two(at.month)}-${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}.kalaobackup';
  }

  static final fileNamePattern = RegExp(
    r'^kalao-\d{4}-\d{2}-\d{2}-\d{4}\.kalaobackup$',
  );

  // Export

  /// Writes a backup of the databases, covers and [settings] (and the
  /// imported audio when [includeMedia]) to [outputPath].
  Future<int> create({
    required String outputPath,
    required AppSettings settings,
    bool includeMedia = false,
    String? requestId,
  }) async {
    final work = await _workDir('export');
    try {
      final entries = <Map<String, String>>[];
      Future<void> snapshot(Database db, String name) async {
        final path = p.join(work.path, name);
        // A consistent copy of a live database (SQLite online backup).
        await db.execute('VACUUM INTO ?', [path]);
        entries.add({'name': name, 'path': path});
      }

      await snapshot(services.library.db, 'library.db');
      await snapshot(services.history.db, 'history.db');
      await snapshot(services.appState.db, 'app_state.db');
      final settingsFile = File(p.join(work.path, 'settings.json'));
      await settingsFile.writeAsString(jsonEncode(settings.toBackupJson()));
      entries.add({'name': 'settings.json', 'path': settingsFile.path});
      var extensionCount = 0;
      if (extensions case final extensions?) {
        try {
          final state = await extensions.backupState();
          final file = File(p.join(work.path, 'extensions.json'));
          await file.writeAsString(jsonEncode(state.json));
          entries.add({'name': 'extensions.json', 'path': file.path});
          for (final MapEntry(key: name, value: path)
              in state.packages.entries) {
            if (File(path).existsSync()) {
              entries.add({'name': name, 'path': path});
              extensionCount++;
            }
          }
        } catch (error) {
          _log.w('Extensions left out of the backup', error);
        }
      }

      final library = services.library.db;
      final covers = await library.rawQuery(
        'SELECT DISTINCT cover_path FROM song WHERE cover_path IS NOT NULL',
      );
      for (final row in covers) {
        _addFile(entries, 'covers', row['cover_path']! as String);
      }
      var mediaFiles = 0;
      if (includeMedia) {
        // Music-folder files stay in their folder (FEATURES 6.8).
        final media = await library.rawQuery(
          "SELECT DISTINCT path FROM media_file WHERE path NOT LIKE 'content://%'",
        );
        for (final row in media) {
          if (_addFile(entries, 'media', row['path']! as String)) mediaFiles++;
        }
      }
      Future<int> count(Database db, String sql) async =>
          Sqflite.firstIntValue(await db.rawQuery(sql)) ?? 0;
      final reply = await PlatformBridge.backupWrite(
        output: outputPath,
        entries: entries,
        manifest: {
          'format': format,
          'app': AppInfo.appName,
          'appVersion': AppInfo.version,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'categories': [
            'library',
            'history',
            'appState',
            'settings',
            if (extensionCount > 0) 'extensions',
            if (includeMedia) 'media',
          ],
          'counts': {
            'songs': await count(library, 'SELECT COUNT(*) FROM song'),
            'favorites': await count(library, 'SELECT COUNT(*) FROM favorite'),
            'plays': await count(
              services.history.db,
              'SELECT COUNT(*) FROM play',
            ),
            'media': mediaFiles,
            'extensions': extensionCount,
          },
          // FEATURES 7.5: secrets stay in secure storage.
          'secrets': false,
        },
        requestId:
            requestId ?? 'backup-${DateTime.now().microsecondsSinceEpoch}',
      );
      _log.i('Backup written: ${entries.length} entries');
      return (reply['bytes'] as num?)?.toInt() ?? 0;
    } finally {
      await _delete(work);
    }
  }

  /// Adds `<folder>/<basename>` for [path] when the file exists.
  bool _addFile(List<Map<String, String>> entries, String folder, String path) {
    if (!File(path).existsSync()) return false;
    final name = '$folder/${p.basename(path)}';
    if (entries.any((entry) => entry['name'] == name)) return false;
    entries.add({'name': name, 'path': path});
    return true;
  }

  // Restore

  /// Checks and extracts the backup at [path] (Rust verifies every entry),
  /// validates and migrates its databases, and returns the preview.
  Future<StagedBackup> inspect(String path, {String? requestId}) async {
    final dir = Directory(
      p.join(
        services.storage.backupWork.path,
        'restore-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      final manifest = await PlatformBridge.backupInspect(
        path: path,
        extractTo: dir.path,
        maxFormat: format,
        requestId:
            requestId ?? 'inspect-${DateTime.now().microsecondsSinceEpoch}',
      );
      final staged = StagedBackup._(dir, manifest, _emptyPreview);
      await _prepare(staged.libraryDb, libraryVersion, libraryMigrations);
      await _prepare(staged.historyDb, historyVersion, historyMigrations);
      await _prepare(staged.appStateDb, appStateVersion, appStateMigrations);
      return StagedBackup._(dir, manifest, await _preview(staged));
    } on PlatformException catch (error) {
      await _delete(dir);
      throw BackupException(error.message ?? '$error');
    } catch (_) {
      await _delete(dir);
      rethrow;
    }
  }

  static const _emptyPreview = BackupPreview(
    createdAt: null,
    appVersion: '',
    songs: 0,
    newSongs: 0,
    plays: 0,
    favorites: 0,
    withLyrics: 0,
    mediaFiles: 0,
    missingMedia: 0,
    bytes: 0,
  );

  /// Refuses a damaged or newer database and migrates an older one in place
  /// (it is our extracted copy).
  Future<void> _prepare(
    String path,
    int version,
    Map<int, List<String>> migrations,
  ) async {
    if (!File(path).existsSync()) {
      throw const BackupException('The backup is missing a database');
    }
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    final int found;
    try {
      final check = await db.rawQuery('PRAGMA integrity_check');
      if (check.firstOrNull?.values.firstOrNull != 'ok') {
        throw const BackupException('A database in the backup is damaged');
      }
      found =
          Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
    } finally {
      await db.close();
    }
    if (found < 1) {
      throw const BackupException('This file is not a Kalao backup');
    }
    if (found > version) {
      throw const BackupException(
        'This backup was made by a newer version of Kalao; update Kalao to '
        'restore it',
      );
    }
    if (found < version) {
      final migrated = await openVersionedDatabase(
        path,
        version: version,
        migrations: migrations,
        factory: _factory,
      );
      await migrated.close();
    }
  }

  Future<BackupPreview> _preview(StagedBackup staged) async {
    final library = await _factory.openDatabase(
      staged.libraryDb,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    final history = await _factory.openDatabase(
      staged.historyDb,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      Future<int> count(Database db, String sql) async =>
          Sqflite.firstIntValue(await db.rawQuery(sql)) ?? 0;
      final keys = {
        for (final row in await services.library.db.query(
          'song',
          columns: ['song_key'],
        ))
          row['song_key'] as String,
      };
      final backupKeys = [
        for (final row in await library.query('song', columns: ['song_key']))
          row['song_key'] as String,
      ];
      final entries =
          (staged.manifest['entries'] as Map?)?.cast<String, dynamic>() ??
          const {};
      var bytes = 0;
      for (final entry in entries.values) {
        bytes += ((entry as Map)['bytes'] as num?)?.toInt() ?? 0;
      }
      // Media files are named by SHA-256, so a file here with the same name
      // is the same audio.
      final missing = <Object?>{
        for (final row in await library.query(
          'media_file',
          columns: ['song_id', 'path'],
        ))
          if (!isDocumentUri(row['path']! as String) &&
              !entries.containsKey(
                'media/${p.basename(row['path']! as String)}',
              ) &&
              !File(_mediaPath(row['path']! as String)).existsSync())
            row['song_id'],
      };
      return BackupPreview(
        createdAt: DateTime.tryParse(
          staged.manifest['createdAt'] as String? ?? '',
        )?.toLocal(),
        appVersion: staged.manifest['appVersion'] as String? ?? '',
        songs: backupKeys.length,
        newSongs: backupKeys.where((key) => !keys.contains(key)).length,
        plays: await count(history, 'SELECT COUNT(*) FROM play'),
        favorites: await count(library, 'SELECT COUNT(*) FROM favorite'),
        withLyrics: await count(
          library,
          'SELECT COUNT(DISTINCT song_id) FROM lyric_doc',
        ),
        mediaFiles: entries.keys.where((k) => k.startsWith('media/')).length,
        missingMedia: missing.length,
        bytes: bytes,
      );
    } finally {
      await library.close();
      await history.close();
    }
  }

  /// Applies [staged] in [mode]. Returns the preferences to apply for
  /// Replace (the backup's, with this device's own keys from [current]; null
  /// for Merge, which keeps the current ones) and the songs Merge added,
  /// whose search keys still need building.
  Future<({AppSettings? settings, List<int> addedSongs})> restore(
    StagedBackup staged,
    RestoreMode mode, {
    required AppSettings current,
  }) async {
    try {
      final safety = mode == RestoreMode.replace
          ? await _writeSafetyBackup(current)
          : null;
      // Files first, so every restored row points at a file that exists.
      await _moveFiles(staged, 'media', services.storage.media);
      await _moveFiles(staged, 'covers', services.storage.covers);
      List<int> added;
      if (safety != null) {
        try {
          await _replaceAll(staged);
        } catch (error) {
          // Each database is replaced in its own transaction: put back the
          // ones already replaced from the safety backup, then fail.
          _log.e('Replace failed; restoring the safety backup', error);
          await _rollBack(safety);
          rethrow;
        }
        added = const []; // search keys came with the songs
      } else {
        added = await _mergeLibrary(staged.libraryDb);
        await _mergeHistory(staged.historyDb);
      }
      await _restoreExtensions(staged);
      AppSettings? settings;
      if (mode == RestoreMode.replace && staged.settings.existsSync()) {
        final json = jsonDecode(await staged.settings.readAsString());
        if (json is Map<String, dynamic>) {
          settings = AppSettings.restoredFrom(json, current);
        }
      }
      _log.i('Restored (${mode.name}): ${added.length} songs added');
      return (settings: settings, addedSongs: added);
    } finally {
      await discard(staged);
    }
  }

  Future<void> discard(StagedBackup staged) => _delete(staged.dir);

  /// Installs the backup's extensions (both modes: an installed newer
  /// version stays) and trusts its repositories again. A failure here never
  /// undoes the library restore.
  Future<void> _restoreExtensions(StagedBackup staged) async {
    final service = extensions;
    final file = File(p.join(staged.dir.path, 'extensions.json'));
    if (service == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) {
        final count = await service.restoreBackup(staged.dir, json);
        _log.i('Restored $count extensions');
      }
    } catch (error) {
      _log.w('Extensions from the backup were not restored', error);
    }
  }

  Future<void> _replaceAll(StagedBackup staged) async {
    await _replace(services.library.db, staged.libraryDb, _libraryTables);
    await _replace(services.history.db, staged.historyDb, const ['play']);
    await _replace(services.appState.db, staged.appStateDb, const [
      'playback_session',
      'recent_access',
      'queue_item',
    ]);
    await _rewritePaths();
  }

  /// Puts the data saved in the safety backup at [path] back.
  Future<void> _rollBack(String path) async {
    StagedBackup? safety;
    try {
      safety = await inspect(path);
      await _replaceAll(safety);
    } catch (error) {
      _log.e('Could not restore the safety backup $path', error);
    } finally {
      if (safety != null) await discard(safety);
    }
  }

  /// Writes a safety backup of the current data and keeps the three newest.
  /// Returns its path.
  Future<String> _writeSafetyBackup(AppSettings current) async {
    final dir = services.storage.safetyBackups;
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'safety-${fileName(DateTime.now())}');
    await create(outputPath: path, settings: current);
    final old =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.kalaobackup'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final file in old.skip(3)) {
      await file.delete();
    }
    return path;
  }

  Future<void> _moveFiles(
    StagedBackup staged,
    String folder,
    Directory target,
  ) async {
    final source = Directory(p.join(staged.dir.path, folder));
    if (!source.existsSync()) return;
    await target.create(recursive: true);
    for (final file in source.listSync().whereType<File>()) {
      final destination = File(p.join(target.path, p.basename(file.path)));
      // Media is named by SHA-256, so an existing file is the same file.
      if (destination.existsSync()) continue;
      await file.rename(destination.path);
    }
  }

  /// Parents first; deleting runs in reverse.
  static const _libraryTables = [
    'song',
    'media_file',
    'lyric_doc',
    'lyric_annotation',
    'song_search',
    'favorite',
    'library_folder',
    'folder_file',
  ];

  Future<T> _withAttached<T>(
    Database db,
    String path,
    Future<T> Function(Transaction txn) body,
  ) async {
    await db.execute('ATTACH DATABASE ? AS src', [path]);
    try {
      return await db.transaction(body);
    } finally {
      await db.execute('DETACH DATABASE src');
    }
  }

  Future<List<String>> _columns(DatabaseExecutor db, String table) async => [
    for (final row in await db.rawQuery('PRAGMA main.table_info($table)'))
      row['name']! as String,
  ];

  Future<void> _replace(
    Database db,
    String path,
    List<String> tables,
  ) => _withAttached(db, path, (txn) async {
    for (final table in tables.reversed) {
      await txn.delete(table);
    }
    for (final table in tables) {
      final columns = (await _columns(txn, table)).join(', ');
      await txn.execute(
        'INSERT INTO main.$table ($columns) SELECT $columns FROM src.$table',
      );
    }
  });

  /// Paths are absolute and differ between devices; files keep their names.
  Future<void> _rewritePaths() => services.library.db.transaction((txn) async {
    final batch = txn.batch();
    for (final row in await txn.query('media_file', columns: ['id', 'path'])) {
      batch.update(
        'media_file',
        {'path': _mediaPath(row['path']! as String)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    for (final row in await txn.query(
      'song',
      columns: ['id', 'cover_path'],
      where: 'cover_path IS NOT NULL',
    )) {
      batch.update(
        'song',
        {'cover_path': _coverPath(row['cover_path']! as String)},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  });

  /// A music-folder file keeps its document URI.
  String _mediaPath(String path) => isDocumentUri(path)
      ? path
      : p.join(services.storage.media.path, p.basename(path));

  String _coverPath(String path) =>
      p.join(services.storage.covers.path, p.basename(path));

  /// Returns the ids of the songs added.
  Future<List<int>> _mergeLibrary(String path) =>
      _withAttached(services.library.db, path, (txn) async {
        final byKey = <String, int>{
          for (final row in await txn.rawQuery(
            'SELECT song_key, MIN(id) AS id FROM main.song GROUP BY song_key',
          ))
            row['song_key']! as String: row['id']! as int,
        };
        final songColumns = (await _columns(
          txn,
          'song',
        )).where((c) => c != 'id').toList();
        final ids = <int, int>{};
        final added = <int>[];
        for (final row in await txn.rawQuery(
          'SELECT * FROM src.song ORDER BY id',
        )) {
          final key = row['song_key']! as String;
          final existing = byKey[key];
          if (existing != null) {
            ids[row['id']! as int] = existing;
            continue;
          }
          final cover = row['cover_path'] as String?;
          final id = await txn.insert('song', {
            for (final column in songColumns) column: row[column],
            'cover_path': cover == null ? null : _coverPath(cover),
          });
          ids[row['id']! as int] = id;
          byKey[key] = id;
          added.add(id);
        }

        final mediaColumns = (await _columns(
          txn,
          'media_file',
        )).where((c) => c != 'id').toList();
        for (final row in await txn.rawQuery('SELECT * FROM src.media_file')) {
          final songId = ids[row['song_id']];
          if (songId == null) continue;
          await txn.insert('media_file', {
            for (final column in mediaColumns) column: row[column],
            'song_id': songId,
            'path': _mediaPath(row['path']! as String),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }

        for (final row in await txn.rawQuery('SELECT * FROM src.favorite')) {
          final songId = ids[row['song_id']];
          if (songId == null) continue;
          await txn.insert('favorite', {
            'song_id': songId,
            'created_at': row['created_at'],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }

        for (final MapEntry(key: from, value: to) in ids.entries) {
          await _mergeLyrics(txn, from, to);
        }
        return added;
      });

  /// The backup's current lyrics become a new version when they are newer
  /// than the library's; the library's `human` layers are kept on lines
  /// whose text did not change.
  Future<void> _mergeLyrics(Transaction txn, int fromSong, int toSong) async {
    final source = (await txn.rawQuery(
      'SELECT * FROM src.lyric_doc WHERE song_id = ? '
      'ORDER BY version DESC LIMIT 1',
      [fromSong],
    )).firstOrNull;
    if (source == null) return;
    final local = (await txn.rawQuery(
      'SELECT * FROM main.lyric_doc WHERE song_id = ? '
      'ORDER BY version DESC LIMIT 1',
      [toSong],
    )).firstOrNull;
    if (local != null &&
        (source['updated_at']! as int) <= (local['updated_at']! as int)) {
      return;
    }
    final layers = <(int, String), Map<String, Object?>>{
      for (final row in await txn.rawQuery(
        'SELECT * FROM src.lyric_annotation WHERE song_id = ? AND doc_version = ?',
        [fromSong, source['version']],
      ))
        (row['line_index']! as int, row['kind']! as String): row,
    };
    if (local != null) {
      final sourceLines = _lineTexts(source['json']! as String);
      final localLines = _lineTexts(local['json']! as String);
      for (final row in await txn.rawQuery(
        "SELECT * FROM main.lyric_annotation WHERE song_id = ? "
        "AND doc_version = ? AND origin = 'human'",
        [toSong, local['version']],
      )) {
        final line = row['line_index']! as int;
        final slot = (line, row['kind']! as String);
        final unchanged =
            line < sourceLines.length &&
            line < localLines.length &&
            sourceLines[line] == localLines[line];
        if (unchanged && layers[slot]?['origin'] != 'human') {
          layers[slot] = row;
        }
      }
    }
    final version = ((local?['version'] as int?) ?? 0) + 1;
    await txn.insert('lyric_doc', {
      'song_id': toSong,
      'version': version,
      'json': source['json'],
      'source_kind': source['source_kind'],
      'updated_at': source['updated_at'],
    });
    for (final row in layers.values) {
      await txn.insert('lyric_annotation', {
        'song_id': toSong,
        'doc_version': version,
        'line_index': row['line_index'],
        'kind': row['kind'],
        'json': row['json'],
        'origin': row['origin'],
      });
    }
    await LibraryDatabase.pruneLyricVersions(txn, toSong, version);
  }

  static List<String> _lineTexts(String json) {
    try {
      final doc = LyricDocument.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>(),
      );
      return [for (final line in doc.lines) line.text];
    } on Object {
      return const [];
    }
  }

  /// Plays are unioned, de-duplicated by `started_at` + `song_key`, and
  /// pointed at the library's song with that key.
  Future<void> _mergeHistory(String path) async {
    final byKey = <String, int>{
      for (final row in await services.library.db.rawQuery(
        'SELECT song_key, MIN(id) AS id FROM song GROUP BY song_key',
      ))
        row['song_key']! as String: row['id']! as int,
    };
    await _withAttached(services.history.db, path, (txn) async {
      final columns = (await _columns(
        txn,
        'play',
      )).where((c) => c != 'id').toList();
      final rows = await txn.rawQuery('''
SELECT * FROM src.play s WHERE NOT EXISTS (
  SELECT 1 FROM main.play m
  WHERE m.started_at = s.started_at AND m.song_key = s.song_key
)''');
      for (final row in rows) {
        await txn.insert('play', {
          for (final column in columns) column: row[column],
          'song_id': byKey[row['song_key']] ?? row['song_id'],
        });
      }
    });
  }

  Future<Directory> _workDir(String kind) async {
    final dir = Directory(
      p.join(
        services.storage.backupWork.path,
        '$kind-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _delete(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException catch (error) {
      _log.w('Could not remove ${dir.path}', error);
    }
  }
}
