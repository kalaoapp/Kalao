import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/lyrics_service.dart';

/// The opened databases and storage. Opened once in `main` (tests open
/// in-memory databases) and injected with `overrideWithValue`.
class LibraryServices {
  LibraryServices({
    required this.storage,
    required this.library,
    required this.history,
    required this.appState,
    required this.importer,
  });

  final AppStorage storage;
  final LibraryDatabase library;
  final HistoryDatabase history;
  final AppStateDatabase appState;
  final ImportService importer;

  LyricsService get lyrics => importer.lyrics;
}

final libraryServicesProvider = Provider<LibraryServices>(
  (ref) => throw StateError('libraryServicesProvider was not overridden'),
);

/// Bumped after every library change; list providers watch it.
final libraryRevisionProvider = NotifierProvider<LibraryRevision, int>(
  LibraryRevision.new,
);

class LibraryRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final librarySongsProvider = FutureProvider.family<List<Song>, SongSort>((
  ref,
  sort,
) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).library.songs(sort: sort);
});

final recentlyAddedProvider = FutureProvider<List<Song>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref
      .watch(libraryServicesProvider)
      .library
      .songs(sort: SongSort.recentlyAdded, limit: 12);
});

final recentlyPlayedProvider = FutureProvider<List<Song>>((ref) async {
  ref.watch(libraryRevisionProvider);
  final services = ref.watch(libraryServicesProvider);
  final ids = await services.history.recentlyPlayedSongIds(limit: 12);
  return services.library.songsByIds(ids);
});

/// The song and position of the last session, for "Continue singing".
final continueSingingProvider =
    FutureProvider<({Song song, Duration position})?>((ref) async {
      ref.watch(libraryRevisionProvider);
      final services = ref.watch(libraryServicesProvider);
      final session = await services.appState.session();
      final id = int.tryParse(session['songId'] ?? '');
      if (id == null) return null;
      final song = await services.library.song(id);
      if (song == null) return null;
      final position = Duration(
        milliseconds: int.tryParse(session['positionMs'] ?? '') ?? 0,
      );
      return (song: song, position: position);
    });

final librarySearchProvider = FutureProvider.family<List<Song>, String>((
  ref,
  query,
) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).library.search(query);
});

final songLyricsProvider = FutureProvider.family<LyricDocument?, int>((
  ref,
  songId,
) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).library.lyrics(songId);
});
