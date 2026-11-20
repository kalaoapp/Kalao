import 'dart:io';

import 'package:kalao/models/song.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/lyrics_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('Import');

/// Converts a file Symphonia cannot decode (Opus, WMA, APE) to FLAC at
/// [output]; returns false on failure. The app uses FFmpegKit.
typedef AudioConverter = Future<bool> Function(String input, String output);

const audioExtensions = {
  'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'oga', 'opus', 'alac', 'mp4', //
  'wma', 'ape', 'aiff', 'aif',
};
const lyricsExtensions = {'lrc', 'txt', 'ttml'};

String _extension(String name) {
  final ext = p.extension(name);
  return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
}

/// A file to import, from the picker or shared to Kalao.
typedef ImportSource = ({String name, Stream<List<int>> Function() read});

/// A picked file copied into staging, with what probing found.
class StagedFile {
  StagedFile({required this.name, required this.path});

  final String name;
  final String path;
  Map<String, dynamic> probe = const {};

  String get extension => _extension(name);
  bool get isAudio => audioExtensions.contains(extension);
  bool get isLyrics => lyricsExtensions.contains(extension);
  int? get durationMs => (probe['durationMs'] as num?)?.toInt();
  String? get tagTitle => _tag('title');
  String? get tagArtist => _tag('artist');

  String? _tag(String key) {
    final value = (probe[key] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

/// One song the import sheet will create; the user can change every part.
class ImportProposal {
  ImportProposal({
    required this.original,
    this.instrumental,
    this.lyrics,
    required this.title,
    this.artist = '',
    this.duplicateOf,
  }) : include = duplicateOf == null;

  StagedFile original;
  StagedFile? instrumental;
  StagedFile? lyrics;
  String title;
  String artist;

  /// Existing song with the same original file (by SHA-256).
  int? duplicateOf;
  bool include;
}

/// Import flow (IMPLEMENTATION.md §3): stage → probe and pair → user
/// confirms → copy to `media/<sha256>`, convert if needed, insert rows,
/// lyrics, search keys.
class ImportService {
  ImportService({
    required this.library,
    required this.storage,
    required this.convert,
  });

  final LibraryDatabase library;
  final AppStorage storage;
  final AudioConverter convert;
  late final lyrics = LyricsService(library);
  var _requests = 0;

  String _requestId() =>
      'import-${DateTime.now().microsecondsSinceEpoch}-${_requests++}';

  /// Copies [bytes] (a picked file's stream) into staging under [name].
  Future<StagedFile> stage(String name, Stream<List<int>> bytes) async {
    await storage.importStaging.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final target = File(
      p.join(
        storage.importStaging.path,
        '${DateTime.now().microsecondsSinceEpoch}_$safe',
      ),
    );
    final sink = target.openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
    return StagedFile(name: name, path: target.path);
  }

  /// Probes audio files, asks Rust for pairings and marks duplicates.
  Future<List<ImportProposal>> propose(List<StagedFile> files) async {
    for (final file in files.where((file) => file.isAudio)) {
      try {
        file.probe = await PlatformBridge.probeAudio(file.path);
      } catch (error) {
        _log.w('Probe failed for ${file.name}', error);
      }
    }
    final pairs = await PlatformBridge.pairImportFiles([
      for (final file in files)
        {'name': file.name, 'durationMs': file.durationMs},
    ]);
    final proposals = <ImportProposal>[];
    for (final pair in pairs) {
      final original = files[(pair['original'] as num).toInt()];
      final instrumental = pair['instrumental'] as num?;
      final lyrics = pair['lyrics'] as num?;
      final sha = await PlatformBridge.hashFile(
        original.path,
        requestId: _requestId(),
      );
      proposals.add(
        ImportProposal(
          original: original,
          instrumental: instrumental == null
              ? null
              : files[instrumental.toInt()],
          lyrics: lyrics == null ? null : files[lyrics.toInt()],
          title:
              original.tagTitle ??
              _titleFromName(pair['title'] as String? ?? original.name),
          artist: original.tagArtist ?? '',
          duplicateOf: await library.songIdForSha(sha),
        ),
      );
    }
    return proposals;
  }

  static String _titleFromName(String stem) =>
      stem.replaceFirst(RegExp(r'^\d+\s*[-._]\s*'), '').trim();

  /// Creates the songs for included proposals. Returns the new song ids.
  Future<List<int>> commit(List<ImportProposal> proposals) async {
    final ids = <int>[];
    for (final proposal in proposals.where((proposal) => proposal.include)) {
      try {
        ids.add(await _commitOne(proposal));
      } catch (error, stack) {
        _log.e('Import failed for ${proposal.original.name}', error, stack);
        rethrow;
      }
    }
    if (ids.isNotEmpty) await refreshSearchKeys(ids);
    await discardStaging();
    return ids;
  }

  Future<int> _commitOne(ImportProposal proposal) async {
    final cover = p.join(
      storage.covers.path,
      'cover_${DateTime.now().microsecondsSinceEpoch}',
    );
    final original = await storeMedia(
      proposal.original,
      MediaKind.original,
      coverBase: cover,
    );
    final media = [original.file];
    if (proposal.instrumental case final instrumental?) {
      media.add((await storeMedia(instrumental, MediaKind.instrumental)).file);
    }
    final probe = proposal.original.probe;
    final id = await library.insertSong(
      NewSong(
        title: proposal.title.trim().isEmpty
            ? proposal.original.name
            : proposal.title.trim(),
        artist: proposal.artist.trim(),
        album: (probe['album'] as String?)?.trim() ?? '',
        durationMs: original.durationMs,
        isrc: probe['isrc'] as String?,
        coverPath: original.coverPath,
        media: media,
      ),
    );
    final embedded = (probe['lyrics'] as String?)?.trim();
    if (proposal.lyrics case final lyrics?) {
      await this.lyrics.importText(
        id,
        await File(lyrics.path).readAsString(),
        source: 'file',
      );
    } else if (embedded != null && embedded.isNotEmpty) {
      await lyrics.importText(id, embedded, source: 'embedded');
    }
    return id;
  }

  /// Hashes [file], copies it to `media/<sha256>.<ext>` (once per hash) and
  /// converts it to FLAC when the engine cannot decode it.
  Future<({NewMediaFile file, int? durationMs, String? coverPath})> storeMedia(
    StagedFile file,
    MediaKind kind, {
    String? coverBase,
  }) async {
    await storage.media.create(recursive: true);
    final sha = await PlatformBridge.hashFile(
      file.path,
      requestId: _requestId(),
    );
    var target = p.join(storage.media.path, '$sha.${file.extension}');
    if (!File(target).existsSync()) {
      await File(file.path).copy(target);
    }
    var probe = await PlatformBridge.probeAudio(target, coverBase: coverBase);
    if (probe['decodable'] != true) {
      final flac = p.join(storage.media.path, '$sha.flac');
      if (!File(flac).existsSync() && !await convert(target, flac)) {
        throw ImportException(
          'Cannot convert ${file.name} to a playable format',
        );
      }
      if (target != flac) await File(target).delete();
      target = flac;
      final converted = await PlatformBridge.probeAudio(target);
      probe = {...probe, ...converted, 'coverPath': probe['coverPath']};
    }
    return (
      file: NewMediaFile(
        kind: kind,
        path: target,
        sha256: sha,
        bytes: await File(target).length(),
        codec: probe['codec'] as String? ?? '',
        sampleRate: (probe['sampleRate'] as num?)?.toInt(),
      ),
      durationMs: (probe['durationMs'] as num?)?.toInt(),
      coverPath: probe['coverPath'] as String?,
    );
  }

  /// Adds or replaces a song's instrumental from a staged file.
  Future<void> setInstrumental(int songId, StagedFile file) async {
    final stored = await storeMedia(file, MediaKind.instrumental);
    await library.setMedia(songId, stored.file);
    await discardStaging();
  }

  /// Rebuilds `song_search` rows (all songs when [ids] is null).
  Future<void> refreshSearchKeys([List<int>? ids]) async {
    final sources = await library.searchSources(ids);
    final rows = await PlatformBridge.rebuildSearchKeys(
      sources,
      requestId: _requestId(),
    );
    await library.replaceSearchKeys(
      ids ?? [for (final source in sources) source['id'] as int],
      rows,
    );
  }

  Future<void> discardStaging() async {
    if (storage.importStaging.existsSync()) {
      await storage.importStaging.delete(recursive: true);
    }
  }

  /// Deletes songs and the media files no other song uses.
  Future<void> deleteSongs(List<Song> songs) async {
    await library.deleteSongs([for (final song in songs) song.id]);
    for (final song in songs) {
      for (final file in song.media) {
        if (!await library.isShaUsed(file.sha256)) {
          final media = File(file.path);
          if (media.existsSync()) await media.delete();
        }
      }
      final cover = song.coverPath;
      if (cover != null && File(cover).existsSync()) await File(cover).delete();
    }
  }
}

class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
