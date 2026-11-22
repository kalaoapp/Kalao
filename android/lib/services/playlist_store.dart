// Local playlists follow the local part of Mornye's collections
// (`library_collections_database.dart`): named, ordered song lists kept in
// the library database (FEATURES 6.14). No imported or catalog playlists.
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.songs = 0,
    this.coverPath,
  });

  final int id;
  final String name;
  final DateTime updatedAt;
  final int songs;

  /// The cover of its first song with one.
  final String? coverPath;

  @override
  bool operator ==(Object other) =>
      other is Playlist &&
      other.id == id &&
      other.name == name &&
      other.updatedAt == updatedAt &&
      other.songs == songs &&
      other.coverPath == coverPath;

  @override
  int get hashCode => Object.hash(id, name, updatedAt, songs, coverPath);
}

/// SQL for `playlist` and `playlist_item` in `kalao_library.db`.
class PlaylistStore {
  PlaylistStore(this.db);

  final Database db;

  Future<List<Playlist>> playlists() async => [
    for (final row in await db.rawQuery('''
SELECT p.*, (SELECT COUNT(*) FROM playlist_item i WHERE i.playlist_id = p.id) AS songs,
  (SELECT s.cover_path FROM playlist_item i JOIN song s ON s.id = i.song_id
     WHERE i.playlist_id = p.id AND s.cover_path IS NOT NULL
     ORDER BY i.position LIMIT 1) AS cover
FROM playlist p ORDER BY p.name COLLATE NOCASE, p.id'''))
      Playlist(
        id: row['id']! as int,
        name: row['name']! as String,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['updated_at']! as int,
        ),
        songs: row['songs'] as int? ?? 0,
        coverPath: row['cover'] as String?,
      ),
  ];

  Future<int> create(String name, {DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return db.insert('playlist', {
      'name': name.trim(),
      'created_at': at,
      'updated_at': at,
    });
  }

  Future<void> rename(int id, String name) => db.update(
    'playlist',
    {'name': name.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> delete(int id) =>
      db.delete('playlist', where: 'id = ?', whereArgs: [id]);

  /// The song ids of playlist [id], in order (a song may appear twice).
  Future<List<({int itemId, int songId})>> items(int id) async => [
    for (final row in await db.query(
      'playlist_item',
      where: 'playlist_id = ?',
      whereArgs: [id],
      orderBy: 'position, id',
    ))
      (itemId: row['id']! as int, songId: row['song_id']! as int),
  ];

  /// Adds [songIds] at the end of playlist [id].
  Future<void> add(int id, List<int> songIds) => db.transaction((txn) async {
    final last =
        Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT MAX(position) FROM playlist_item WHERE playlist_id = ?',
            [id],
          ),
        ) ??
        -1;
    for (final (index, songId) in songIds.indexed) {
      await txn.insert('playlist_item', {
        'playlist_id': id,
        'position': last + 1 + index,
        'song_id': songId,
      });
    }
    await _touch(txn, id);
  });

  Future<void> removeItem(int id, int itemId) => db.transaction((txn) async {
    await txn.delete('playlist_item', where: 'id = ?', whereArgs: [itemId]);
    await _touch(txn, id);
  });

  /// Writes the order of [itemIds] (all of playlist [id]'s items).
  Future<void> reorder(int id, List<int> itemIds) =>
      db.transaction((txn) async {
        for (final (position, itemId) in itemIds.indexed) {
          await txn.update(
            'playlist_item',
            {'position': position},
            where: 'id = ? AND playlist_id = ?',
            whereArgs: [itemId, id],
          );
        }
        await _touch(txn, id);
      });

  static Future<void> _touch(DatabaseExecutor executor, int id) =>
      executor.update(
        'playlist',
        {'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );
}
