// Find Missing Artwork, after Mornye's library_album_artwork_provider.dart:
// one album at a time through the artwork extensions, cancellable, with
// what was found (or not) remembered per album (FEATURES 6.13).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/library_maintenance.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Artwork');

@immutable
class AlbumArtworkRun {
  const AlbumArtworkRun({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.found = 0,
  });

  final bool running;
  final int done;
  final int total;
  final int found;

  @override
  bool operator ==(Object other) =>
      other is AlbumArtworkRun &&
      other.running == running &&
      other.done == done &&
      other.total == total &&
      other.found == found;

  @override
  int get hashCode => Object.hash(running, done, total, found);
}

final albumArtworkProvider =
    NotifierProvider<AlbumArtworkController, AlbumArtworkRun>(
      AlbumArtworkController.new,
    );

class AlbumArtworkController extends Notifier<AlbumArtworkRun> {
  var _cancel = false;

  @override
  AlbumArtworkRun build() => const AlbumArtworkRun();

  void cancel() => _cancel = true;

  /// Whether an enabled extension can draw artwork.
  Future<bool> hasArtworkExtension() async {
    final listed = await ref.read(extensionServiceProvider).list();
    return listed.extensions.any(
      (extension) =>
          extension.enabled &&
          extension.manifest.has(ExtensionCapability.artwork),
    );
  }

  /// Looks up every album without artwork; the number of covers found, or
  /// null when no album needed one.
  Future<int?> run() async {
    if (state.running) return null;
    final services = ref.read(libraryServicesProvider);
    final maintenance = services.maintenance;
    final extensions = ref.read(extensionServiceProvider);
    final albums = await maintenance.albumsMissingArtwork();
    if (albums.isEmpty) return null;
    _cancel = false;
    state = AlbumArtworkRun(running: true, total: albums.length);
    var found = 0;
    try {
      for (final album in albums) {
        if (_cancel) break;
        final songs = await maintenance.albumSongs(album.ref);
        final sample = songs.firstOrNull;
        String? cover;
        if (sample != null) {
          cover = await extensions.downloadArtwork(
            TrackResult(
              extensionId: '',
              id: '',
              title: sample.title,
              artists: [album.ref.artist],
              album: album.ref.name,
              durationMs: sample.durationMs,
              isrc: sample.isrc,
            ),
          );
        }
        if (cover != null) {
          await maintenance.applyCover(album.ref, cover);
          found++;
        } else {
          await maintenance.recordArtwork(album.ref, AlbumArtworkState.none);
        }
        if (!ref.mounted) return found;
        state = AlbumArtworkRun(
          running: true,
          done: state.done + 1,
          total: albums.length,
          found: found,
        );
      }
    } catch (error, stack) {
      _log.e('Find Missing Artwork stopped', error, stack);
    } finally {
      if (ref.mounted) {
        state = AlbumArtworkRun(
          done: state.done,
          total: albums.length,
          found: found,
        );
        if (found > 0) ref.read(libraryRevisionProvider.notifier).bump();
      }
    }
    return found;
  }
}
