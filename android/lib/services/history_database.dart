import 'package:flutter/foundation.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:sqflite/sqflite.dart';

/// `play.mode`.
enum PlayMode { listen, karaoke, learn }

/// A song and a count, a duration in ms or a score.
typedef SongStat = ({int songId, num value});

/// The stats screen's numbers (FEATURES 6.7), from `play` rows.
@immutable
class PlayStats {
  const PlayStats({
    required this.plays,
    required this.timeSung,
    required this.songs,
    required this.days,
    required this.topSongs,
    required this.mostPractised,
    required this.bestScores,
  });

  final int plays;
  final Duration timeSung;

  /// Distinct songs played.
  final int songs;

  /// Oldest first, one entry per local day.
  final List<({DateTime day, int plays, int ms})> days;
  final List<SongStat> topSongs;

  /// By time spent in Learn mode (ms).
  final List<SongStat> mostPractised;

  /// Scores 0–100; empty until scoring exists (M7).
  final List<SongStat> bestScores;
}

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

  /// Totals, the last [days] days, top songs, Learn-mode time and best
  /// scores (FEATURES 6.7). SQLite aggregates the rows; only the per-day
  /// buckets of the last [days] days are summed here, in local time.
  Future<PlayStats> stats({DateTime? now, int days = 7, int top = 5}) async {
    final today = now ?? DateTime.now();
    final from = DateTime(today.year, today.month, today.day - (days - 1));
    final totals = (await db.rawQuery(
      'SELECT COUNT(*) AS plays, COALESCE(SUM(duration_ms), 0) AS ms, '
      'COUNT(DISTINCT song_id) AS songs FROM play',
    )).first;
    final recent = await db.query(
      'play',
      columns: ['started_at', 'duration_ms'],
      where: 'started_at >= ?',
      whereArgs: [from.millisecondsSinceEpoch],
    );
    final buckets = [
      for (var i = 0; i < days; i++)
        (day: DateTime(from.year, from.month, from.day + i), plays: 0, ms: 0),
    ];
    for (final row in recent) {
      final at = DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int);
      final day = DateTime(at.year, at.month, at.day);
      // Rounded so a daylight-saving day (23 or 25 h) stays one day.
      final index = (day.difference(from).inHours / 24).round();
      if (index < 0 || index >= days) continue;
      final bucket = buckets[index];
      buckets[index] = (
        day: bucket.day,
        plays: bucket.plays + 1,
        ms: bucket.ms + (row['duration_ms'] as int? ?? 0),
      );
    }
    Future<List<SongStat>> ranked(String sql) async => [
      for (final row in await db.rawQuery(sql, [top]))
        (songId: row['song_id'] as int, value: row['value'] as num),
    ];
    return PlayStats(
      plays: totals['plays'] as int? ?? 0,
      timeSung: Duration(milliseconds: totals['ms'] as int? ?? 0),
      songs: totals['songs'] as int? ?? 0,
      days: buckets,
      topSongs: await ranked(
        'SELECT song_id, COUNT(*) AS value FROM play GROUP BY song_id '
        'ORDER BY value DESC, MAX(started_at) DESC LIMIT ?',
      ),
      mostPractised: await ranked(
        "SELECT song_id, SUM(duration_ms) AS value FROM play WHERE mode = 'learn' "
        'GROUP BY song_id HAVING value > 0 ORDER BY value DESC LIMIT ?',
      ),
      bestScores: await ranked(
        'SELECT song_id, MAX(score) AS value FROM play WHERE score IS NOT NULL '
        'GROUP BY song_id ORDER BY value DESC LIMIT ?',
      ),
    );
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
