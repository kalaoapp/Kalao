import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_queue_store.dart';

/// A queue row with its song.
@immutable
class QueueEntry {
  const QueueEntry(this.item, this.song);

  final QueueItem item;
  final Song song;
}

/// The singing queue in order. Entries whose song was deleted are skipped.
final queueProvider = FutureProvider<List<QueueEntry>>((ref) async {
  ref.watch(libraryRevisionProvider);
  final services = ref.watch(libraryServicesProvider);
  final items = await services.queue.items();
  final songs = {
    for (final song in await services.library.songsByIds(
      {for (final item in items) item.songId}.toList(),
    ))
      song.id: song,
  };
  return [
    for (final item in items)
      if (songs[item.songId] case final song?) QueueEntry(item, song),
  ];
});

final queueActionsProvider = Provider<QueueActions>(QueueActions.new);

/// Changes to the queue; each one refreshes [queueProvider].
class QueueActions {
  QueueActions(this._ref);

  final Ref _ref;

  QueueStore get _store => _ref.read(libraryServicesProvider).queue;

  void _changed() => _ref.read(libraryRevisionProvider.notifier).bump();

  Future<void> add(
    Song song, {
    String singer = '',
    PlayMode mode = PlayMode.karaoke,
  }) async {
    await _store.add(song.id, singer: singer, mode: mode);
    _changed();
  }

  Future<void> remove(QueueItem item) async {
    await _store.remove(item.id);
    _changed();
  }

  Future<void> move(int from, int to) async {
    await _store.move(from, to);
    _changed();
  }

  Future<void> update(QueueItem item, {String? singer, PlayMode? mode}) async {
    await _store.update(item.id, singer: singer, mode: mode);
    _changed();
  }

  Future<void> clear() async {
    await _store.clear();
    _changed();
  }

  /// Plays [entry] now and takes it off the queue.
  Future<void> play(QueueEntry entry) async {
    await _store.remove(entry.item.id);
    await _ref
        .read(playerProvider.notifier)
        .playSong(entry.song, mode: entry.item.mode, singer: entry.item.singer);
  }
}
