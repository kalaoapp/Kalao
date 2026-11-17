import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:sqflite/sqflite.dart';

/// `play.mode`.
enum PlayMode { listen, karaoke, learn }

/// `kalao_history.db`: one `play` row per performance (DATA_MODEL.md §2).
class HistoryDatabase {
  HistoryDatabase(this.db);

  final Database db;

  static Future<HistoryDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async => HistoryDatabase(
    await openVersionedDatabase(
      path,
      version: historyVersion,
      migrations: historyMigrations,
      factory: factory,
    ),
  );

  Future<void> close() => db.close();

  Future<int> startPlay({
    required int songId,
    required String songKey,
    required PlayMode mode,
    String singer = '',
    DateTime? now,
  }) => db.insert('play', {
    if (singer.isNotEmpty) 'singer': singer,
    'song_id': songId,
    'song_key': songKey,
    'started_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    'mode': mode.name,
  });

  Future<void> finishPlay(
    int playId, {
    required Duration listened,
    PlayMode? mode,
  }) => db.update(
    'play',
    {'duration_ms': listened.inMilliseconds, 'mode': ?mode?.name},
    where: 'id = ?',
    whereArgs: [playId],
  );

  /// Song ids by most recent play, each once.
  Future<List<int>> recentlyPlayedSongIds({int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT song_id, MAX(started_at) AS last FROM play '
      'GROUP BY song_id ORDER BY last DESC LIMIT ?',
      [limit],
    );
    return [for (final row in rows) row['song_id'] as int];
  }

  Future<void> forgetSongs(List<int> songIds) async {
    if (songIds.isEmpty) return;
    await db.delete(
      'play',
      where: 'song_id IN (${List.filled(songIds.length, '?').join(',')})',
      whereArgs: songIds,
    );
  }
}

/// `kalao_app_state.db`: playback session restore and recent access.
class AppStateDatabase {
  AppStateDatabase(this.db);

  final Database db;

  static Future<AppStateDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async => AppStateDatabase(
    await openVersionedDatabase(
      path,
      version: appStateVersion,
      migrations: appStateMigrations,
      factory: factory,
    ),
  );

  Future<void> close() => db.close();

  Future<Map<String, String>> session() async => {
    for (final row in await db.query('playback_session'))
      row['key'] as String: row['value'] as String? ?? '',
  };

  Future<void> saveSession(Map<String, String> values) =>
      db.transaction((txn) async {
        await txn.delete('playback_session');
        for (final MapEntry(:key, :value) in values.entries) {
          await txn.insert('playback_session', {'key': key, 'value': value});
        }
      });

  Future<void> clearSession() => db.delete('playback_session');
}
