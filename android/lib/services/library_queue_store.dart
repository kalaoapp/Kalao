import 'package:flutter/foundation.dart';
import 'package:kalao/services/history_database.dart';
import 'package:sqflite/sqflite.dart';

/// One `queue_item` row (DATA_MODEL.md §2): a song waiting to be sung, with
/// who sings it and in which mode.
@immutable
class QueueItem {
  const QueueItem({
    required this.id,
    required this.songId,
    this.singer = '',
    this.mode = PlayMode.karaoke,
  });

  final int id;
  final int songId;

  /// Free text; empty when nobody was named.
  final String singer;
  final PlayMode mode;

  @override
  bool operator ==(Object other) =>
      other is QueueItem &&
      other.id == id &&
      other.songId == songId &&
      other.singer == singer &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(id, songId, singer, mode);
}

/// The singing queue in `kalao_app_state.db` (Mornye's
/// `library_queue_store.dart` role, with Kalao's singer and mode). Rows are
/// ordered by `position`, which is rewritten densely on every change.
class QueueStore {
  QueueStore(this.db);

  final Database db;

  Future<List<QueueItem>> items() async => [
    for (final row in await db.query('queue_item', orderBy: 'position, id'))
      QueueItem(
        id: row['id'] as int,
        songId: row['song_id'] as int,
        singer: row['singer'] as String? ?? '',
        mode: PlayMode.values.asNameMap()[row['mode']] ?? PlayMode.karaoke,
      ),
  ];

  /// Appends [songId]; returns the new row id.
  Future<int> add(
    int songId, {
    String singer = '',
    PlayMode mode = PlayMode.karaoke,
  }) => db.transaction((txn) async {
    final last = Sqflite.firstIntValue(
      await txn.rawQuery('SELECT MAX(position) FROM queue_item'),
    );
    return txn.insert('queue_item', {
      'song_id': songId,
      'position': (last ?? -1) + 1,
      'singer': singer.trim(),
      'mode': mode.name,
      'added_by': 'host',
    });
  });

  Future<void> remove(int id) =>
      db.delete('queue_item', where: 'id = ?', whereArgs: [id]);

  /// Drops entries of deleted songs.
  Future<void> removeSongs(List<int> songIds) async {
    if (songIds.isEmpty) return;
    await db.delete(
      'queue_item',
      where: 'song_id IN (${List.filled(songIds.length, '?').join(',')})',
      whereArgs: songIds,
    );
  }

  Future<void> clear() => db.delete('queue_item');

  Future<void> update(int id, {String? singer, PlayMode? mode}) async {
    final values = {'singer': ?singer?.trim(), 'mode': ?mode?.name};
    if (values.isEmpty) return;
    await db.update('queue_item', values, where: 'id = ?', whereArgs: [id]);
  }

  /// Moves the entry at index [from] to index [to] (indices into [items]).
  Future<void> move(int from, int to) => db.transaction((txn) async {
    final ids = [
      for (final row in await txn.query(
        'queue_item',
        columns: ['id'],
        orderBy: 'position, id',
      ))
        row['id'] as int,
    ];
    if (from < 0 || from >= ids.length) return;
    final id = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), id);
    for (final (position, id) in ids.indexed) {
      await txn.update(
        'queue_item',
        {'position': position},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  });

  /// Removes and returns the first entry, or null when the queue is empty.
  Future<QueueItem?> takeFirst() async {
    final first = (await items()).firstOrNull;
    if (first != null) await remove(first.id);
    return first;
  }
}
