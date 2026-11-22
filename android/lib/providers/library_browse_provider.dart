// Bounded Library reads, after Mornye's library_browse_provider.dart and
// library_counts_provider.dart: lists read one page at a time, equal
// queries share their count, and every read follows the library revision.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/services/playlist_store.dart';

/// Songs per page of a Library list.
const libraryPageSize = 100;

typedef SongPage = ({SongQuery query, int page});

final songPageProvider = FutureProvider.family<List<Song>, SongPage>((
  ref,
  key,
) {
  ref.watch(libraryRevisionProvider);
  return ref
      .watch(libraryServicesProvider)
      .browse
      .page(
        key.query,
        offset: key.page * libraryPageSize,
        limit: libraryPageSize,
      );
});

final songCountProvider = FutureProvider.family<int, SongQuery>((ref, query) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.count(query);
});

final libraryCodecsProvider = FutureProvider<List<String>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.codecs();
});

/// Albums, all or of one artist.
final albumsProvider = FutureProvider.family<List<AlbumSummary>, String?>((
  ref,
  artist,
) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.albums(artist: artist);
});

final artistsProvider = FutureProvider<List<ArtistSummary>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.artists();
});

final genresProvider = FutureProvider<List<GenreSummary>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.genres();
});

final folderLevelProvider = FutureProvider.family<FolderLevel, FolderRef>((
  ref,
  folder,
) {
  ref.watch(libraryRevisionProvider);
  return ref
      .watch(libraryServicesProvider)
      .browse
      .folderLevel(folder.folderId, folder.dir);
});

final folderSongsProvider = FutureProvider.family<List<Song>, FolderRef>((
  ref,
  folder,
) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).browse.folderSongs(folder);
});

final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).playlists.playlists();
});

/// A playlist's entries in order, with their songs.
final playlistSongsProvider =
    FutureProvider.family<List<({int itemId, Song song})>, int>((
      ref,
      id,
    ) async {
      ref.watch(libraryRevisionProvider);
      final services = ref.watch(libraryServicesProvider);
      final items = await services.playlists.items(id);
      final songs = {
        for (final song in await services.library.songsByIds(
          items.map((item) => item.songId).toSet().toList(),
        ))
          song.id: song,
      };
      return [
        for (final item in items)
          if (songs[item.songId] case final song?)
            (itemId: item.itemId, song: song),
      ];
    });

/// The song keys of [keys] that are in the library ("In Library" on
/// extension results).
final knownSongKeysProvider = FutureProvider.family<Set<String>, String>((
  ref,
  joinedKeys,
) {
  ref.watch(libraryRevisionProvider);
  return ref
      .watch(libraryServicesProvider)
      .browse
      .knownKeys(joinedKeys.split('\n').where((key) => key.isNotEmpty));
});

/// The songs of [ids] in a random order (Shuffle).
List<int> shuffled(List<int> ids, [Random? random]) =>
    [...ids]..shuffle(random);
