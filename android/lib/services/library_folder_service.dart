// Music folders follow Mornye's local library (`local_library_provider_scan
// .dart`, `MainActivitySafScan.kt`): folders granted once with SAF, files
// read in place through descriptors, incremental rescans by size and
// modification time, removed files leave the library. Written Kalao-sized:
// pairing per directory, lyrics files and no tag cache.
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
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('Folders');

/// `media_file.source` and `lyric_doc.source_kind` of music-folder files.
const folderSource = 'folder';

/// What one scan changed.
class FolderScanResult {
  const FolderScanResult({
    this.added = const [],
    this.updated = 0,
    this.removed = 0,
    this.skipped = 0,
    this.lostAccess = false,
    this.cancelled = false,
  });

  /// Ids of the songs the scan added.
  final List<int> added;
  final int updated;
  final int removed;
  final int skipped;
  final bool lostAccess;
  final bool cancelled;

  bool get changed => added.isNotEmpty || updated > 0 || removed > 0;
}

class FolderOverlapException implements Exception {
  const FolderOverlapException(this.other);

  /// The music folder the new one is inside of, or contains.
  final String other;

  @override
  String toString() => 'Overlaps the music folder $other';
}

/// Reports scan progress: audio files read so far of [total].
typedef FolderScanProgress = void Function(int done, int total);

/// Adds, scans and removes music folders (FEATURES 6.8). Songs from a folder
/// keep their files where they are: `media_file.path` is the document URI,
/// `source` is [folderSource] and `sha256` is empty. Lyrics, layers,
/// favorites and plays are the library's like any song's.
class LibraryFolderService {
  LibraryFolderService({
    required this.library,
    required this.importer,
    required this.storage,
  });

  final LibraryDatabase library;
  final ImportService importer;
  final AppStorage storage;
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

  /// Brings the library in line with the folder: songs for new audio files
  /// (paired with an instrumental and a lyrics file from the same
  /// directory), updated details for changed ones, and songs whose original
  /// is gone removed. When the folder cannot be read nothing is removed.
  /// [cancelled] is checked between files; what was done stays.
  Future<FolderScanResult> scan(
    LibraryFolder folder, {
    FolderScanProgress? onProgress,
    bool Function()? cancelled,
  }) async {
    final listing = await PlatformBridge.listLibraryFolder(folder.treeUri);
    if (listing == null) {
      _log.w('No access to ${folder.name}');
      await store.setScanned(folder.id, error: LibraryFolder.lostAccess);
      return const FolderScanResult(lostAccess: true);
    }
    final scan = _Scan(this, folder, listing, onProgress, cancelled);
    final result = await scan.run();
    await store.setScanned(
      folder.id,
      at: result.cancelled ? null : DateTime.now(),
    );
    if (result.added.isNotEmpty) await importer.refreshSearchKeys(result.added);
    _log.i(
      '${folder.name}: ${result.added.length} added, ${result.updated} '
      'updated, ${result.removed} removed, ${result.skipped} skipped',
    );
    return result;
  }
}

bool _isAudio(String name) => audioExtensions.contains(
  p.extension(name).replaceFirst('.', '').toLowerCase(),
);

bool _isLyrics(String name) => lyricsExtensions.contains(
  p.extension(name).replaceFirst('.', '').toLowerCase(),
);

/// An audio file read for this scan.
class _Probed {
  _Probed(this.entry, this.probe);

  final FolderEntry entry;
  final Map<String, dynamic> probe;

  int? get durationMs => (probe['durationMs'] as num?)?.toInt();
  String? get coverPath => probe['coverPath'] as String?;

  String? tag(String key) {
    final value = (probe[key] as String?)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  NewMediaFile media(MediaKind kind) => NewMediaFile(
    kind: kind,
    path: entry.uri,
    sha256: '',
    bytes: entry.bytes,
    codec: probe['codec'] as String? ?? '',
    sampleRate: (probe['sampleRate'] as num?)?.toInt(),
    source: folderSource,
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
  );

  final LibraryFolderService service;
  final LibraryFolder folder;
  final List<FolderEntry> listing;
  final FolderScanProgress? onProgress;
  final bool Function()? cancelled;

  LibraryDatabase get library => service.library;
  LibraryFolderStore get store => service.store;

  final added = <int>[];
  int updated = 0;
  int removed = 0;
  int skipped = 0;
  int done = 0;
  int total = 0;
  bool stopped = false;

  bool get _stop => stopped = stopped || (cancelled?.call() ?? false);

  Future<FolderScanResult> run() async {
    var known = await store.files(folder.id);
    final seen = {for (final entry in listing) entry.uri: entry};
    await _removeGone(known, seen);
    known = await store.files(folder.id);

    final changed = <(FolderEntry, FolderFile)>[];
    final fresh = <FolderEntry>[];
    for (final entry in listing) {
      final file = known[entry.uri];
      if (file == null || file.role == FolderFileRole.skipped) {
        if (file == null || _differs(entry, file)) fresh.add(entry);
      } else if (_differs(entry, file)) {
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
      skipped: skipped,
      cancelled: stopped,
    );
  }

  static bool _differs(FolderEntry entry, FolderFile file) =>
      entry.bytes != file.bytes || entry.modified != file.modified;

  void _progress() => onProgress?.call(++done, total);

  /// A song whose original is gone leaves the library; its other files are
  /// forgotten so this scan pairs them again (a renamed original keeps its
  /// instrumental and lyrics). A gone instrumental leaves its song; lyrics
  /// stay in the library.
  Future<void> _removeGone(
    Map<String, FolderFile> known,
    Map<String, FolderEntry> seen,
  ) async {
    final gone = [
      for (final file in known.values)
        if (!seen.containsKey(file.uri)) file,
    ];
    if (gone.isEmpty) return;
    final songs = <int>{};
    for (final file in gone) {
      final songId = file.songId;
      if (songId == null) continue;
      switch (file.role) {
        case FolderFileRole.original:
          songs.add(songId);
        case FolderFileRole.instrumental:
          await library.removeMedia(songId, MediaKind.instrumental);
          updated++;
        case FolderFileRole.lyrics || FolderFileRole.skipped:
          break;
      }
    }
    await store.deleteFiles([for (final file in gone) file.uri]);
    if (songs.isEmpty) return;
    await store.deleteFilesOfSongs(songs);
    await service.importer.deleteSongs(
      await library.songsByIds(songs.toList()),
    );
    removed += songs.length;
  }

  /// Reads a changed file again: new codec, size and duration for audio,
  /// new lyrics unless the song's lyrics were edited or fetched since.
  Future<void> _update(FolderEntry entry, FolderFile file) async {
    final songId = file.songId;
    var next = FolderFile(
      uri: entry.uri,
      folderId: folder.id,
      dir: entry.dir,
      name: entry.name,
      role: file.role,
      songId: songId,
      bytes: entry.bytes,
      modified: entry.modified,
    );
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
          codec: probed.probe['codec'] as String? ?? '',
          sampleRate: (probed.probe['sampleRate'] as num?)?.toInt(),
        );
        if (kind == MediaKind.original && probed.durationMs != null) {
          await library.updateDetails(songId, durationMs: probed.durationMs);
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
      if (read.probe['decodable'] != true) {
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

  /// Adds [instrumental] (when the song has none) and [lyric] (when it has
  /// no lyrics) to a song already in the library; whether the instrumental
  /// was added.
  Future<bool> _join(
    Song song,
    _Probed? instrumental,
    FolderEntry? lyric,
  ) async {
    var joined = false;
    if (instrumental != null && song.file(MediaKind.instrumental) == null) {
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
    final title =
        original.tag('title') ??
        (guessedTitle ?? p.basenameWithoutExtension(original.entry.name))
            .replaceFirst(RegExp(r'^\d+\s*[-._]\s*'), '')
            .trim();
    if (instrumental != null) await _deleteCover(instrumental.coverPath);
    final id = await library.insertSong(
      NewSong(
        title: title.isEmpty ? original.entry.name : title,
        artist: original.tag('artist') ?? '',
        album: original.tag('album') ?? '',
        durationMs: original.durationMs,
        isrc: original.tag('isrc'),
        coverPath: original.coverPath,
        media: [
          original.media(MediaKind.original),
          ?instrumental?.media(MediaKind.instrumental),
        ],
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

  /// Tags, duration and decodability through a descriptor; null when it
  /// cannot be read.
  Future<_Probed?> _probe(FolderEntry entry, {String? coverBase}) async {
    try {
      final probe = await _withDocument(
        entry,
        (path) => PlatformBridge.probeAudio(path, coverBase: coverBase),
      );
      return _Probed(entry, probe);
    } catch (error) {
      _log.w('Cannot read ${entry.dir}/${entry.name}', error);
      return null;
    }
  }

  Future<String?> _readText(FolderEntry entry) async {
    try {
      return await _withDocument(
        entry,
        (path) async =>
            utf8.decode(await File(path).readAsBytes(), allowMalformed: true),
      );
    } catch (error) {
      _log.w('Cannot read ${entry.dir}/${entry.name}', error);
      return null;
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
