// Review duplicates and Find Missing Artwork follow Mornye's
// `library_duplicates.dart` and `library_album_artwork.dart`, adapted:
// duplicates are songs sharing a song key across folders, imports and
// downloads, and keeping one moves the others' lyrics, favorites, plays,
// queue and playlist entries to it; artwork comes from artwork extensions
// and is saved in the app, with what was found or removed remembered per
// album (FEATURES 6.13).
import 'package:kalao/models/song.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_queue_store.dart';

/// `album_artwork.state`.
enum AlbumArtworkState { found, none, removed }

class LibraryMaintenance {
  LibraryMaintenance({
    required this.library,
    required this.history,
    required this.queue,
    required this.importer,
  });

  final LibraryDatabase library;
  final HistoryDatabase history;
  final QueueStore queue;
  final ImportService importer;

  /// Songs that share a song key (ISRC, or title + artist + length), the
  /// oldest first in each group.
  Future<List<List<Song>>> duplicateGroups() async {
    final keys = [
      for (final row in await library.db.rawQuery('''
SELECT song_key FROM song GROUP BY song_key HAVING COUNT(*) > 1
ORDER BY MIN(title) COLLATE NOCASE'''))
        row['song_key']! as String,
    ];
    final groups = <List<Song>>[];
    for (final key in keys) {
      final rows = await library.db.query(
        'song',
        where: 'song_key = ?',
        whereArgs: [key],
        orderBy: 'added_at, id',
      );
      groups.add(await library.songsFromRows(rows));
    }
    return groups;
  }

  /// Keeps [kept] and deletes [others]: their plays, queue and playlist
  /// entries move to it, it becomes a favorite if one of them was, and it
  /// takes the newest lyrics of theirs when it has none. Files in music
  /// folders stay on disk (and later scans leave them out).
  Future<void> keep(Song kept, List<Song> others) async {
    final ids = [
      for (final song in others)
        if (song.id != kept.id) song.id,
    ];
    if (ids.isEmpty) return;
    final marks = List.filled(ids.length, '?').join(',');
    await library.db.transaction((txn) async {
      final hasLyrics = (await txn.query(
        'lyric_doc',
        where: 'song_id = ?',
        whereArgs: [kept.id],
        limit: 1,
      )).isNotEmpty;
      if (!hasLyrics) {
        final newest = await txn.rawQuery(
          'SELECT song_id FROM lyric_doc WHERE song_id IN ($marks) '
          'ORDER BY updated_at DESC LIMIT 1',
          ids,
        );
        if (newest.isNotEmpty) {
          final from = newest.first['song_id']! as int;
          for (final table in const ['lyric_doc', 'lyric_annotation']) {
            await txn.update(
              table,
              {'song_id': kept.id},
              where: 'song_id = ?',
              whereArgs: [from],
            );
          }
        }
      }
      final favorite = await txn.rawQuery(
        'SELECT 1 FROM favorite WHERE song_id IN ($marks) LIMIT 1',
        ids,
      );
      if (favorite.isNotEmpty) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO favorite(song_id, created_at) VALUES (?, ?)',
          [kept.id, DateTime.now().millisecondsSinceEpoch],
        );
      }
      await txn.rawUpdate(
        'UPDATE playlist_item SET song_id = ? WHERE song_id IN ($marks)',
        [kept.id, ...ids],
      );
    });
    await history.db.rawUpdate(
      'UPDATE play SET song_id = ?, song_key = ? WHERE song_id IN ($marks)',
      [kept.id, kept.songKey, ...ids],
    );
    await queue.db.rawUpdate(
      'UPDATE queue_item SET song_id = ? WHERE song_id IN ($marks)',
      [kept.id, ...ids],
    );
    await importer.deleteSongs(await library.songsByIds(ids));
  }

  /// Albums none of whose songs has a cover and that were not looked up
  /// before (or whose cover the user removed).
  Future<List<AlbumSummary>> albumsMissingArtwork() async {
    final looked = {
      for (final row in await library.db.query('album_artwork'))
        row['album_key']! as String,
    };
    return [
      for (final album in await LibraryBrowse(library).albums())
        if (album.coverPath == null && !looked.contains(album.ref.key)) album,
    ];
  }

  Future<void> recordArtwork(AlbumRef album, AlbumArtworkState state) =>
      library.db.rawInsert(
        'INSERT OR REPLACE INTO album_artwork(album_key, state, checked_at) '
        'VALUES (?, ?, ?)',
        [album.key, state.name, DateTime.now().millisecondsSinceEpoch],
      );

  /// The songs of [album] (for a lookup's sample and for applying a cover).
  Future<List<Song>> albumSongs(AlbumRef album) =>
      LibraryBrowse(library).page(SongQuery(album: album), limit: 1000);

  /// Gives the album's songs without a cover the found [coverPath].
  Future<void> applyCover(AlbumRef album, String coverPath) async {
    for (final song in await albumSongs(album)) {
      if (song.coverPath == null) {
        await library.updateDetails(song.id, coverPath: coverPath);
      }
    }
    await recordArtwork(album, AlbumArtworkState.found);
  }

  /// Takes the album's cover away and remembers it, so Find Missing
  /// Artwork does not put it back.
  Future<void> removeCover(AlbumRef album) async {
    final songs = await albumSongs(album);
    final covers = {for (final song in songs) ?song.coverPath};
    await library.db.update(
      'song',
      {'cover_path': null},
      where: 'id IN (${List.filled(songs.length, '?').join(',')})',
      whereArgs: [for (final song in songs) song.id],
    );
    await recordArtwork(album, AlbumArtworkState.removed);
    await importer.deleteUnusedCovers(covers);
  }
}
