// Music folders follow Mornye's local library (`local_library_provider_scan
// .dart`, `MainActivitySafScan.kt`, `library_cleanup.dart`, `cover/folder.rs`):
// folders granted once with SAF, files read in place through descriptors,
// incremental rescans by size, modification time and reader version, offline
// sources kept, missing files cleaned up on request. Written Kalao-sized:
// pairing per directory, lyrics files, relinking by song key, no tag cache
// (MORNYE_REUSE.md §7).
import 'dart:convert';
import 'dart:io';

import 'package:kalao/models/library_folder.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_folder_store.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/document_tree.dart';
import 'package:kalao/utils/folder_cover.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('Folders');

/// `media_file.source` and `lyric_doc.source_kind` of music-folder files.
const folderSource = 'folder';

/// Formats the engine cannot decode that FFmpegKit converts on first play
/// (FEATURES 6.8).
const convertedExtensions = {
  'opus', 'ape', 'wv', 'mpc', 'dsf', 'dff', 'wma', //
};

/// The newest converted copies kept, in bytes.
const convertedCacheBytes = 1024 * 1024 * 1024;

/// FFprobe and FFmpeg over a music-folder document (`main.dart` passes
/// FFmpegKit's; tests pass stand-ins). [probe] returns `probeAudio`-shaped
/// tags (title, artist, album, albumArtist, genre, year, trackNo, discNo,
/// durationMs, codec) or null when the file cannot be read; [convert] writes
/// a FLAC copy to `output`.
class FolderTranscoder {
  const FolderTranscoder({required this.probe, required this.convert});

  final Future<Map<String, dynamic>?> Function(String uri) probe;
  final Future<bool> Function(String uri, String output) convert;

  /// No FFmpegKit: undecodable formats stay skipped.
  static final none = FolderTranscoder(
    probe: (_) async => null,
    convert: (_, _) async => false,
  );
}

/// What one scan changed.
class FolderScanResult {
  const FolderScanResult({
    this.added = const [],
    this.updated = 0,
    this.removed = 0,
    this.relinked = 0,
    this.skipped = 0,
    this.lostAccess = false,
    this.offline = false,
    this.cancelled = false,
  });

  /// Ids of the songs the scan added.
  final List<int> added;
  final int updated;

  /// Songs whose original disappeared (now unavailable, FEATURES 6.9).
  final int removed;

  /// Missing songs a new file stood in for.
  final int relinked;
  final int skipped;
  final bool lostAccess;
  final bool offline;
  final bool cancelled;

  bool get changed =>
      added.isNotEmpty || updated > 0 || removed > 0 || relinked > 0;
}

class FolderOverlapException implements Exception {
  const FolderOverlapException(this.other);

  /// The music folder the new one is inside of, or contains.
  final String other;

  @override
  String toString() => 'Overlaps the music folder $other';
}

/// The song cannot play: its original is gone or its folder is offline.
class SongUnavailableException implements Exception {
  const SongUnavailableException(this.title);

  final String title;

  @override
  String toString() => '$title is not available';
}

/// Reports scan progress: audio files read so far of [total].
typedef FolderScanProgress = void Function(int done, int total);

/// Adds, scans and removes music folders (FEATURES 6.8, 6.9). Songs from a
/// folder keep their files where they are: `media_file.path` is the
/// document URI, `source` is [folderSource] and `sha256` is empty. Lyrics,
/// layers, favorites and plays are the library's like any song's, and stay
/// while the file is gone until [cleanupMissing].
class LibraryFolderService {
  LibraryFolderService({
    required this.library,
    required this.importer,
    required this.storage,
    FolderTranscoder? transcoder,
  }) : transcoder = transcoder ?? FolderTranscoder.none;

  final LibraryDatabase library;
  final ImportService importer;
  final AppStorage storage;
  final FolderTranscoder transcoder;
  late final store = LibraryFolderStore(library.db);

  Future<List<LibraryFolder>> folders() => store.folders();

  /// Adds the granted folder [treeUri] (picking a folder that is already a
  /// music folder returns it, so access lost earlier comes back). Throws
  /// [FolderOverlapException] when it is inside another music folder or
  /// contains one.
  Future<LibraryFolder> addFolder(String treeUri) async {
    for (final folder in await store.folders()) {
      if (folder.treeUri == treeUri) return folder;
      if (treesOverlap(folder.treeUri, treeUri)) {
        throw FolderOverlapException(folder.name);
      }
    }
    final id = await store.addFolder(treeUri, treeFolderName(treeUri));
    return (await store.folder(id))!;
  }

  /// Removes the folder and its songs from the library; the files stay.
  Future<int> removeFolder(LibraryFolder folder) async {
    final songs = await library.songsByIds(await store.songIds(folder.id));
    await importer.deleteSongs(songs);
    await store.removeFolder(folder.id);
    return songs.length;
  }

  Future<List<SkippedFolderFile>> skipped(LibraryFolder folder) =>
      store.skipped(folder.id);

  /// Music-folder songs whose original is gone (FEATURES 6.9).
  Future<List<int>> missingSongs() => library.missingSongIds();

  /// Deletes the songs whose original is gone, with their lyrics and plays
  /// in this library; the files of their other parts are forgotten so a
  /// later scan pairs them again. Returns how many songs were deleted.
  Future<int> cleanupMissing() async {
    final ids = await library.missingSongIds();
    if (ids.isEmpty) return 0;
    await store.deleteFilesOfSongs(ids);
    await importer.deleteSongs(await library.songsByIds(ids));
    return ids.length;
  }

  /// Brings the library in line with the folder: songs for new audio files
  /// (paired with an instrumental and a lyrics file from the same
  /// directory), updated details for changed ones, and songs whose original
  /// is gone marked unavailable; a new file with the key of such a song is
  /// relinked to it. When the folder cannot be read (offline storage, lost
  /// access) its songs are unavailable and nothing is removed. [full] reads
  /// every file again (Force Full Scan). [cancelled] is checked between
  /// files; what was done stays.
  Future<FolderScanResult> scan(
    LibraryFolder folder, {
    FolderScanProgress? onProgress,
    bool Function()? cancelled,
    bool full = false,
  }) async {
    final listing = await PlatformBridge.listLibraryFolder(folder.treeUri);
    if (listing.state != FolderListingState.ok) {
      final offline = listing.state == FolderListingState.offline;
      _log.w('${folder.name} is ${offline ? 'offline' : 'not accessible'}');
      await library.setAvailable(await store.mediaUris(folder.id), false);
      await store.setScanned(
        folder.id,
        error: offline ? LibraryFolder.offline : LibraryFolder.lostAccess,
      );
      return FolderScanResult(lostAccess: !offline, offline: offline);
    }
    final scan = _Scan(
      this,
      folder,
      listing.files,
      onProgress,
      cancelled,
      full,
    );
    final result = await scan.run();
    await store.setScanned(
      folder.id,
      at: result.cancelled ? null : DateTime.now(),
    );
    if (result.added.isNotEmpty) await importer.refreshSearchKeys(result.added);
    _log.i(
      '${folder.name}: ${result.added.length} added, ${result.updated} '
      'updated, ${result.relinked} relinked, ${result.removed} gone, '
      '${result.skipped} skipped',
    );
    return result;
  }

  /// The files to load for [song] (kind → path), with a FLAC copy in place
  /// of a music-folder file the engine cannot decode (converted once, on
  /// first play). Throws [SongUnavailableException] when the original is
  /// gone or offline; an unavailable instrumental is left out.
  Future<Map<String, String>> playableSources(Song song) async {
    if (song.unavailable) throw SongUnavailableException(song.title);
    final sources = <String, String>{};
    for (final file in song.media) {
      if (!file.available) continue;
      sources[file.kind.name] = file.decodable || !file.inFolder
          ? file.path
          : await _converted(file);
    }
    return sources;
  }

  Future<String> _converted(MediaFile file) async {
    await storage.converted.create(recursive: true);
    final target = File(
      p.join(storage.converted.path, '${_fnv(file.path)}-${file.bytes}.flac'),
    );
    if (target.existsSync()) {
      await target.setLastModified(DateTime.now());
      return target.path;
    }
    final partial = File('${target.path}.part');
    if (!await transcoder.convert(file.path, partial.path) ||
        !partial.existsSync()) {
      if (partial.existsSync()) await partial.delete();
      throw StateError('Cannot convert ${file.path} to a playable format');
    }
    await partial.rename(target.path);
    await _pruneConverted(keep: target.path);
    return target.path;
  }

  /// Keeps the newest [convertedCacheBytes] of converted copies.
  Future<void> _pruneConverted({required String keep}) async {
    final files = storage.converted.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    var total = 0;
    for (final file in files) {
      total += file.lengthSync();
      if (total > convertedCacheBytes && file.path != keep) await file.delete();
    }
  }

  /// FNV-1a over the URI: a stable file name for its converted copy.
  static String _fnv(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(text)) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }
}

bool _isAudio(String name) {
  final extension = _extension(name);
  return audioExtensions.contains(extension) ||
      convertedExtensions.contains(extension);
}

bool _isLyrics(String name) => lyricsExtensions.contains(_extension(name));

String _extension(String name) =>
    p.extension(name).replaceFirst('.', '').toLowerCase();

/// An audio file read for this scan.
class _Probed {
  _Probed(this.entry, this.probe, {this.decodable = true});

  final FolderEntry entry;
  final Map<String, dynamic> probe;

  /// False when FFprobe read it and it plays from a converted copy.
  final bool decodable;

  int? get durationMs => (probe['durationMs'] as num?)?.toInt();
  String? get coverPath => probe['coverPath'] as String?;
  set coverPath(String? path) => probe['coverPath'] = path;

  String? tag(String key) {
    final value = (probe[key] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  SongTags get tags => SongTags.fromProbe(probe);

  NewMediaFile media(MediaKind kind) => NewMediaFile(
    kind: kind,
    path: entry.uri,
    sha256: '',
    bytes: entry.bytes,
    codec: probe['codec'] as String? ?? _extension(entry.name),
    sampleRate: (probe['sampleRate'] as num?)?.toInt(),
    source: folderSource,
    decodable: decodable,
  );
}

/// One run of [LibraryFolderService.scan].
class _Scan {
  _Scan(
    this.service,
    this.folder,
    this.listing,
    this.onProgress,
    this.cancelled,
    this.full,
  );

  final LibraryFolderService service;
  final LibraryFolder folder;
  final List<FolderEntry> listing;
  final FolderScanProgress? onProgress;
  final bool Function()? cancelled;
  final bool full;

  LibraryDatabase get library => service.library;
  LibraryFolderStore get store => service.store;

  final added = <int>[];
  int updated = 0;
  int removed = 0;
  int relinked = 0;
  int skipped = 0;
  int done = 0;
  int total = 0;
  bool stopped = false;

  /// Folder images copied into `covers/` this scan, by document URI.
  final _folderCovers = <String, String?>{};

  bool get _stop => stopped = stopped || (cancelled?.call() ?? false);

  Future<FolderScanResult> run() async {
    var known = await store.files(folder.id);
    final seen = {for (final entry in listing) entry.uri: entry};
    await _removeGone(known, seen);
    known = await store.files(folder.id);
    // The folder is readable again: its files are back.
    await library.setAvailable([
      for (final file in known.values)
        if (file.songId != null && seen.containsKey(file.uri)) file.uri,
    ], true);

    final changed = <(FolderEntry, FolderFile)>[];
    final fresh = <FolderEntry>[];
    for (final entry in listing) {
      if (folderImageRank(entry.name) != null) continue;
      final file = known[entry.uri];
      if (file == null || file.role == FolderFileRole.skipped) {
        if (file == null || full || _differs(entry, file)) fresh.add(entry);
      } else if (full || _differs(entry, file)) {
        changed.add((entry, file));
      }
    }
    total =
        fresh.where((entry) => _isAudio(entry.name)).length +
        changed.where((change) => _isAudio(change.$1.name)).length;
    onProgress?.call(0, total);

    for (final (entry, file) in changed) {
      if (_stop) break;
      await _update(entry, file);
    }
    final byDir = <String, List<FolderEntry>>{};
    for (final entry in fresh) {
      (byDir[entry.dir] ??= []).add(entry);
    }
    for (final MapEntry(key: dir, value: entries) in byDir.entries) {
      if (_stop) break;
      await _addDirectory(dir, entries, known);
    }
    return FolderScanResult(
      added: added,
      updated: updated,
      removed: removed,
      relinked: relinked,
      skipped: skipped,
      cancelled: stopped,
    );
  }

  /// Changed since it was read, or read by an older reader.
  static bool _differs(FolderEntry entry, FolderFile file) =>
      entry.bytes != file.bytes ||
      entry.modified != file.modified ||
      (file.role != FolderFileRole.lyrics &&
          file.scanVersion < folderScanVersion);

  void _progress() => onProgress?.call(++done, total);

  /// A song whose original is gone stays in the library, unavailable, with
  /// its other files (FEATURES 6.9); a file with its key relinks it. A gone
  /// instrumental leaves its song; lyrics stay in the library.
  Future<void> _removeGone(
    Map<String, FolderFile> known,
    Map<String, FolderEntry> seen,
  ) async {
    final gone = [
      for (final file in known.values)
        if (!seen.containsKey(file.uri)) file,
    ];
    if (gone.isEmpty) return;
    final originals = <String>[];
    for (final file in gone) {
      final songId = file.songId;
      if (songId == null) continue;
      switch (file.role) {
        case FolderFileRole.original:
          originals.add(file.uri);
          removed++;
        case FolderFileRole.instrumental:
          await library.removeMedia(songId, MediaKind.instrumental);
          updated++;
        case FolderFileRole.lyrics || FolderFileRole.skipped:
          break;
      }
    }
    await library.setAvailable(originals, false);
    await store.deleteFiles([for (final file in gone) file.uri]);
  }

  /// Reads a changed file again: new codec, size and duration for audio
  /// (tags the song lacks are filled in), new lyrics unless the song's
  /// lyrics were edited or fetched since.
  Future<void> _update(FolderEntry entry, FolderFile file) async {
    final songId = file.songId;
    var next = _row(entry, file.role, songId);
    if (songId == null) {
      // Its song was deleted: only remember the new size.
      if (_isAudio(entry.name)) _progress();
    } else if (_isAudio(entry.name)) {
      final probed = await _probe(entry);
      _progress();
      if (probed != null) {
        final kind = file.role == FolderFileRole.instrumental
            ? MediaKind.instrumental
            : MediaKind.original;
        await library.updateMediaDetails(
          songId,
          kind,
          bytes: entry.bytes,
          codec: probed.media(kind).codec,
          sampleRate: (probed.probe['sampleRate'] as num?)?.toInt(),
        );
        if (kind == MediaKind.original) {
          if (probed.durationMs != null) {
            await library.updateDetails(songId, durationMs: probed.durationMs);
          }
          await library.fillTags(songId, probed.tags);
          await _fillCover(songId, probed);
        } else {
          await _deleteCover(probed.coverPath);
        }
        updated++;
      } else {
        // Unreadable now: keep the old size so the next scan tries again.
        next = file;
      }
    } else if (file.role == FolderFileRole.lyrics) {
      final kind = await library.lyricsSourceKind(songId);
      if (kind == null || kind == folderSource || kind == 'embedded') {
        final text = await _readText(entry);
        if (text != null) {
          await service.importer.lyrics.importText(
            songId,
            text,
            source: folderSource,
          );
          updated++;
        } else {
          next = file;
        }
      }
    }
    await store.putFile(next);
  }

  /// A song without a cover takes [probed]'s embedded one, else its
  /// folder image.
  Future<void> _fillCover(int songId, _Probed probed) async {
    final song = await library.song(songId);
    if (song == null || song.coverPath != null) {
      await _deleteCover(probed.coverPath);
      return;
    }
    final cover = probed.coverPath ?? await _folderCover(probed.entry.dir);
    if (cover != null) await library.updateDetails(songId, coverPath: cover);
  }

  /// New files of one directory: originals become songs with a paired
  /// instrumental and lyrics file; an instrumental or lyrics file that
  /// pairs with a song already here is added to it.
  Future<void> _addDirectory(
    String dir,
    List<FolderEntry> entries,
    Map<String, FolderFile> known,
  ) async {
    final probed = <_Probed>[];
    Future<void> dropCovers() async {
      for (final read in probed) {
        await _deleteCover(read.coverPath);
      }
    }

    for (final entry in entries.where((entry) => _isAudio(entry.name))) {
      if (_stop) return dropCovers();
      final read = await _probe(
        entry,
        coverBase: p.join(
          service.storage.covers.path,
          'cover_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      _progress();
      if (read == null) {
        await _skip(entry, 'unreadable');
        continue;
      }
      if (!read.decodable && !_canConvert(entry)) {
        await _deleteCover(read.coverPath);
        await _skip(entry, 'format');
        continue;
      }
      probed.add(read);
    }
    final lyrics = [
      for (final entry in entries)
        if (_isLyrics(entry.name)) entry,
    ];
    if (probed.isEmpty && lyrics.isEmpty) return;

    // Songs already in this directory, so new files can join them.
    final here = [
      for (final file in known.values)
        if (file.dir == dir &&
            file.role == FolderFileRole.original &&
            file.songId != null)
          file,
    ];
    final songs = {
      for (final song in await library.songsByIds([
        for (final file in here) file.songId!,
      ]))
        song.id: song,
    };
    final existing = [
      for (final file in here)
        if (songs[file.songId] case final song?) (file: file, song: song),
    ];
    final names = <Map<String, Object?>>[
      for (final item in existing)
        {'name': item.file.name, 'durationMs': item.song.durationMs},
      for (final item in probed)
        {'name': item.entry.name, 'durationMs': item.durationMs},
      for (final entry in lyrics) {'name': entry.name},
    ];
    final pairs = await PlatformBridge.pairImportFiles(names);

    final usedAudio = <int>{};
    for (final pair in pairs) {
      if (_stop) {
        // The rest is read again next time.
        for (var i = 0; i < probed.length; i++) {
          if (!usedAudio.contains(i)) await _deleteCover(probed[i].coverPath);
        }
        return;
      }
      final original = (pair['original'] as num).toInt();
      _Probed? audioAt(Object? index) {
        final i = (index as num?)?.toInt();
        if (i == null) return null;
        final j = i - existing.length;
        return j >= 0 && j < probed.length ? probed[j] : null;
      }

      FolderEntry? lyricsAt(Object? index) {
        final i = (index as num?)?.toInt();
        if (i == null) return null;
        final j = i - existing.length - probed.length;
        return j >= 0 && j < lyrics.length ? lyrics[j] : null;
      }

      final instrumental = audioAt(pair['instrumental']);
      final lyric = lyricsAt(pair['lyrics']);
      if (original < existing.length) {
        final item = existing[original];
        if (await _join(item.song, instrumental, lyric)) {
          usedAudio.add(probed.indexOf(instrumental!));
        }
        continue;
      }
      final read = audioAt(original);
      if (read == null) continue;
      usedAudio.add(probed.indexOf(read));
      if (instrumental != null) usedAudio.add(probed.indexOf(instrumental));
      await _addSong(read, instrumental, lyric, pair['title'] as String?);
    }
    // An instrumental for a song that has one: seen, not added.
    for (var i = 0; i < probed.length; i++) {
      if (usedAudio.contains(i)) continue;
      await _deleteCover(probed[i].coverPath);
      await store.putFile(_row(probed[i].entry, FolderFileRole.instrumental));
    }
  }

  /// Adds [instrumental] (when the song has none, or its own is gone) and
  /// [lyric] (when it has no lyrics) to a song already in the library;
  /// whether the instrumental was added.
  Future<bool> _join(
    Song song,
    _Probed? instrumental,
    FolderEntry? lyric,
  ) async {
    var joined = false;
    if (instrumental != null &&
        !(song.file(MediaKind.instrumental)?.available ?? false)) {
      await library.setMedia(
        song.id,
        instrumental.media(MediaKind.instrumental),
      );
      await _deleteCover(instrumental.coverPath);
      await store.putFile(
        _row(instrumental.entry, FolderFileRole.instrumental, song.id),
      );
      updated++;
      joined = true;
    }
    if (lyric != null && !song.hasLyrics) {
      if (await _importLyrics(song.id, lyric)) updated++;
    }
    return joined;
  }

  Future<void> _addSong(
    _Probed original,
    _Probed? instrumental,
    FolderEntry? lyric,
    String? guessedTitle,
  ) async {
    final rawTitle =
        original.tag('title') ??
        (guessedTitle ?? p.basenameWithoutExtension(original.entry.name))
            .replaceFirst(RegExp(r'^\d+\s*[-._]\s*'), '')
            .trim();
    final title = rawTitle.isEmpty ? original.entry.name : rawTitle;
    final artist = original.tag('artist') ?? '';
    if (instrumental != null) await _deleteCover(instrumental.coverPath);

    // A moved or renamed file, or a song restored from a backup: the missing
    // song with this key takes the file and keeps its lyrics and plays.
    final missing = await library.missingSongIdForKey(
      LibraryDatabase.songKey(
        title,
        artist,
        original.durationMs,
        original.tag('isrc'),
      ),
    );
    if (missing != null) {
      await library.setMedia(missing, original.media(MediaKind.original));
      await store.putFile(
        _row(original.entry, FolderFileRole.original, missing),
      );
      await library.fillTags(missing, original.tags);
      await _fillCover(missing, original);
      final song = await library.song(missing);
      if (song != null) await _join(song, instrumental, lyric);
      relinked++;
      return;
    }

    final id = await library.insertSong(
      NewSong(
        title: title,
        artist: artist,
        album: original.tag('album') ?? '',
        durationMs: original.durationMs,
        isrc: original.tag('isrc'),
        coverPath: original.coverPath ?? await _folderCover(original.entry.dir),
        media: [
          original.media(MediaKind.original),
          ?instrumental?.media(MediaKind.instrumental),
        ],
        tags: original.tags,
      ),
    );
    added.add(id);
    await store.putFile(_row(original.entry, FolderFileRole.original, id));
    if (instrumental != null) {
      await store.putFile(
        _row(instrumental.entry, FolderFileRole.instrumental, id),
      );
    }
    if (lyric != null && await _importLyrics(id, lyric)) return;
    final embedded = original.tag('lyrics');
    if (embedded != null) {
      await service.importer.lyrics.importText(
        id,
        embedded,
        source: 'embedded',
      );
    }
  }

  /// The folder image of [dir] (or of its parent, for a disc folder such
  /// as `CD1`), copied once into `covers/` and shared by its songs.
  Future<String?> _folderCover(String dir) async {
    FolderEntry? image(String directory) {
      final here = [
        for (final entry in listing)
          if (entry.dir == directory) entry,
      ];
      final name = folderImage([for (final entry in here) entry.name]);
      return name == null ? null : here.firstWhere((e) => e.name == name);
    }

    var found = image(dir);
    if (found == null &&
        dir.isNotEmpty &&
        isDiscFolder(p.posix.basename(dir))) {
      found = image(dir.contains('/') ? p.posix.dirname(dir) : '');
    }
    if (found == null) return null;
    final entry = found;
    if (_folderCovers.containsKey(entry.uri)) return _folderCovers[entry.uri];
    final target = p.join(
      service.storage.covers.path,
      'folder_${LibraryFolderService._fnv(entry.uri)}_${entry.modified}'
      '${p.extension(entry.name).toLowerCase()}',
    );
    String? path;
    try {
      if (!File(target).existsSync()) {
        await PlatformBridge.copyDocumentToFile(entry.uri, target);
      }
      path = File(target).existsSync() ? target : null;
    } catch (error) {
      _log.w('Cannot read ${entry.dir}/${entry.name}', error);
    }
    return _folderCovers[entry.uri] = path;
  }

  Future<bool> _importLyrics(int songId, FolderEntry entry) async {
    final text = await _readText(entry);
    if (text == null || text.trim().isEmpty) return false;
    try {
      await service.importer.lyrics.importText(
        songId,
        text,
        source: folderSource,
      );
    } catch (error) {
      _log.w('Cannot import lyrics ${entry.name}', error);
      return false;
    }
    await store.putFile(_row(entry, FolderFileRole.lyrics, songId));
    return true;
  }

  FolderFile _row(FolderEntry entry, FolderFileRole role, [int? songId]) =>
      FolderFile(
        uri: entry.uri,
        folderId: folder.id,
        dir: entry.dir,
        name: entry.name,
        role: role,
        songId: songId,
        bytes: entry.bytes,
        modified: entry.modified,
      );

  Future<void> _skip(FolderEntry entry, String reason) async {
    skipped++;
    await store.putFile(
      FolderFile(
        uri: entry.uri,
        folderId: folder.id,
        dir: entry.dir,
        name: entry.name,
        role: FolderFileRole.skipped,
        bytes: entry.bytes,
        modified: entry.modified,
        error: reason,
      ),
    );
  }

  /// Whether FFmpegKit can convert [entry] on first play.
  bool _canConvert(FolderEntry entry) =>
      convertedExtensions.contains(_extension(entry.name)) &&
      transcoderAvailable;

  bool get transcoderAvailable =>
      !identical(service.transcoder, FolderTranscoder.none);

  /// Tags, duration and decodability through a descriptor (FFprobe for a
  /// format Symphonia cannot open); null when it cannot be read.
  Future<_Probed?> _probe(FolderEntry entry, {String? coverBase}) async {
    Map<String, dynamic>? symphonia;
    try {
      final read = await _withDocument(
        entry,
        (path) => PlatformBridge.probeAudio(path, coverBase: coverBase),
      );
      if (read['decodable'] == true) return _Probed(entry, read);
      symphonia = read;
    } catch (error) {
      if (!convertedExtensions.contains(_extension(entry.name))) {
        _log.w('Cannot read ${entry.dir}/${entry.name}', error);
        return null;
      }
    }
    if (convertedExtensions.contains(_extension(entry.name)) &&
        transcoderAvailable) {
      try {
        final tags = await service.transcoder.probe(entry.uri);
        if (tags != null) {
          return _Probed(entry, {
            ...?symphonia,
            ...tags,
            'coverPath': symphonia?['coverPath'],
          }, decodable: false);
        }
      } catch (error) {
        _log.w('FFprobe cannot read ${entry.dir}/${entry.name}', error);
      }
    }
    if (symphonia != null) return _Probed(entry, symphonia, decodable: false);
    return null;
  }

  /// A lyrics file's text, streamed through the host (no descriptor
  /// reopen, ADR-018).
  Future<String?> _readText(FolderEntry entry) async {
    final scratch = service.storage.folderScratch;
    final copy = File(
      p.join(scratch.path, 'lyrics_${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      await scratch.create(recursive: true);
      await PlatformBridge.copyDocumentToFile(entry.uri, copy.path);
      return utf8.decode(await copy.readAsBytes(), allowMalformed: true);
    } catch (error) {
      _log.w('Cannot read ${entry.dir}/${entry.name}', error);
      return null;
    } finally {
      if (copy.existsSync()) await copy.delete();
    }
  }

  static Future<T> _withDocument<T>(
    FolderEntry entry,
    Future<T> Function(String path) body,
  ) async {
    final document = await PlatformBridge.openDocument(entry.uri);
    try {
      return await body(document.path);
    } finally {
      await PlatformBridge.closeDocuments([document.handle]);
    }
  }

  static Future<void> _deleteCover(String? path) async {
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
