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

/// What storing a staged file in `media/` produced.
typedef StoredMedia = ({NewMediaFile file, int? durationMs, String? coverPath});

/// A picked file copied into staging, with what inspecting it found.
class StagedFile {
  StagedFile({required this.name, required this.path});

  final String name;
  final String path;
  Map<String, dynamic> probe = const {};

  /// Set by [ImportService.propose] for audio files.
  String? sha256;

  /// Set once the file has moved into `media/` (a file paired with two songs
  /// is stored once).
  StoredMedia? stored;

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

/// Import flow (IMPLEMENTATION.md §3): stage → inspect (hash + probe) and
/// pair → user confirms → move to `media/<sha256>`, convert if needed,
/// insert rows, lyrics, search keys. Each file's bytes are read once (the
/// hash); staging and `media/` share a file system, so storing is a rename.
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

  /// Hashes and probes audio files, asks Rust for pairings and marks
  /// duplicates.
  Future<List<ImportProposal>> propose(List<StagedFile> files) async {
    for (final file in files.where((file) => file.isAudio)) {
      try {
        final inspected = await PlatformBridge.importInspect(
          file.path,
          requestId: _requestId(),
        );
        file
          ..sha256 = inspected.sha256
          ..probe = inspected.probe ?? const {};
      } catch (error) {
        _log.w('Inspect failed for ${file.name}', error);
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
      final sha = original.sha256;
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
          duplicateOf: sha == null ? null : await library.songIdForSha(sha),
        ),
      );
    }
    return proposals;
  }

  static String _titleFromName(String stem) =>
      stem.replaceFirst(RegExp(r'^\d+\s*[-._]\s*'), '').trim();

  /// Creates the songs for included proposals. Returns the new song ids.
  /// When one fails, the songs before it stay (complete, with search keys),
  /// that song's files are removed unless another song uses them, staging is
  /// cleared and the error is rethrown.
  Future<List<int>> commit(List<ImportProposal> proposals) async {
    final ids = <int>[];
    try {
      for (final proposal in proposals.where((proposal) => proposal.include)) {
        try {
          ids.add(await _commitOne(proposal));
        } catch (error, stack) {
          _log.e('Import failed for ${proposal.original.name}', error, stack);
          await _removeUnused(proposal);
          rethrow;
        }
      }
    } finally {
      if (ids.isNotEmpty) await refreshSearchKeys(ids);
      await discardStaging();
    }
    return ids;
  }

  /// The media and cover a failed proposal left behind, unless a song uses
  /// them.
  Future<void> _removeUnused(ImportProposal proposal) async {
    final stored = [?proposal.original.stored, ?proposal.instrumental?.stored];
    final used = await library.usedShas([
      for (final media in stored) media.file.sha256,
    ]);
    for (final media in stored) {
      if (!used.contains(media.file.sha256)) await _deleteFile(media.file.path);
      if (media.coverPath case final cover?) await _deleteFile(cover);
    }
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

  /// Moves [file] to `media/<sha256>.<ext>` (once per hash, by rename) and
  /// converts it to FLAC when the engine cannot decode it.
  Future<StoredMedia> storeMedia(
    StagedFile file,
    MediaKind kind, {
    String? coverBase,
  }) async {
    if (file.stored case final stored?) {
      return (
        file: NewMediaFile(
          kind: kind,
          path: stored.file.path,
          sha256: stored.file.sha256,
          bytes: stored.file.bytes,
          codec: stored.file.codec,
          sampleRate: stored.file.sampleRate,
        ),
        durationMs: stored.durationMs,
        coverPath: null,
      );
    }
    final sha =
        file.sha256 ??
        (await PlatformBridge.importInspect(
          file.path,
          requestId: _requestId(),
        )).sha256;
    final moved = await PlatformBridge.importStore(
      path: file.path,
      sha256: sha,
      mediaDir: storage.media.path,
      coverBase: coverBase,
      requestId: _requestId(),
    );
    var target = moved.path;
    var bytes = moved.bytes;
    var probe = moved.probe ?? const <String, dynamic>{};
    if (probe['decodable'] != true) {
      final flac = p.join(storage.media.path, '$sha.flac');
      if (!File(flac).existsSync() && !await convert(target, flac)) {
        // Nothing points at the moved file or its cover yet.
        if (!(await library.usedShas([sha])).contains(sha)) {
          await _deleteFile(target);
        }
        if (probe['coverPath'] case final String cover) {
          await _deleteFile(cover);
        }
        throw ImportException(
          'Cannot convert ${file.name} to a playable format',
        );
      }
      if (target != flac) await _deleteFile(target);
      target = flac;
      bytes = await File(target).length();
      final converted = await PlatformBridge.probeAudio(target);
      probe = {...probe, ...converted, 'coverPath': probe['coverPath']};
    }
    final stored = (
      file: NewMediaFile(
        kind: kind,
        path: target,
        sha256: sha,
        bytes: bytes,
        codec: probe['codec'] as String? ?? '',
        sampleRate: (probe['sampleRate'] as num?)?.toInt(),
      ),
      durationMs: (probe['durationMs'] as num?)?.toInt(),
      coverPath: probe['coverPath'] as String?,
    );
    file.stored = stored;
    return stored;
  }

  /// Adds or replaces a song's instrumental from a staged file.
  Future<void> setInstrumental(int songId, StagedFile file) async {
    try {
      final stored = await storeMedia(file, MediaKind.instrumental);
      await library.setMedia(songId, stored.file);
    } finally {
      await discardStaging();
    }
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
    final used = await library.usedShas([
      for (final song in songs)
        for (final file in song.media) file.sha256,
    ]);
    for (final song in songs) {
      for (final file in song.media) {
        if (!used.contains(file.sha256)) await _deleteFile(file.path);
      }
      if (song.coverPath case final cover?) await _deleteFile(cover);
    }
  }

  static Future<void> _deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}

class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
