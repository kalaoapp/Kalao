import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/lyrics_language_guess.dart';
import 'package:kalao/services/lyrics_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/services/secure_storage_options.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('Extensions');

/// Where extension secrets live: Keystore-backed secure storage in the app,
/// memory in tests. Backups never read it (FEATURES 7.5).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this.storage = secureStorage]);

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class ExtensionException implements Exception {
  const ExtensionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app side of extensions (IMPLEMENTATION.md §10): starts the Rust
/// manager, keeps `secret` settings in secure storage, runs login flows,
/// and turns extension results into library songs, lyrics, artwork and
/// offline files. Every Rust call goes through [PlatformBridge].
class ExtensionService {
  ExtensionService({
    required this.storage,
    required this.library,
    required this.importer,
    SecretStore? secrets,
  }) : secrets = secrets ?? const SecureSecretStore();

  final AppStorage storage;
  final LibraryDatabase library;
  final ImportService importer;
  final SecretStore secrets;

  LyricsService get lyrics => importer.lyrics;

  Future<List<ExtensionInfo>>? _started;
  int _requests = 0;

  static String secretKey(String extensionId, String key) =>
      'ext:$extensionId:$key';

  /// Opens the installed extensions once and hands Rust their secrets.
  Future<List<ExtensionInfo>> start({bool developerMode = false}) =>
      _started ??= _start(developerMode);

  Future<List<ExtensionInfo>> _start(bool developerMode) async {
    final installed = await PlatformBridge.extensionsInit(
      root: storage.extensions.path,
      streamCache: storage.streamCache.path,
      appVersion: AppInfo.version,
      developerMode: developerMode,
    );
    for (final extension in installed) {
      await _pushSecrets(extension.manifest);
    }
    return installed;
  }

  Future<void> _pushSecrets(ExtensionManifest manifest) async {
    final values = <String, String>{};
    for (final setting in manifest.secretSettings) {
      try {
        final value = await secrets.read(secretKey(manifest.id, setting.key));
        if (value != null && value.isNotEmpty) values[setting.key] = value;
      } catch (error) {
        _log.w('Could not read a secret of ${manifest.id}', error);
      }
    }
    if (values.isNotEmpty) {
      await PlatformBridge.setExtensionSecrets(manifest.id, values);
    }
  }

  /// Runs [call] after start-up and stores any secrets the extensions set
  /// while it ran (a refreshed login token, say).
  Future<T> _call<T>(Future<T> Function() call) async {
    await start();
    try {
      return await call();
    } finally {
      await _applySecretUpdates();
    }
  }

  Future<void> _applySecretUpdates() async {
    try {
      final updates = await PlatformBridge.takeExtensionSecretUpdates();
      for (final MapEntry(key: id, value: values) in updates.entries) {
        for (final MapEntry(:key, :value) in values.entries) {
          if (value == null || value.isEmpty) {
            await secrets.delete(secretKey(id, key));
          } else {
            await secrets.write(secretKey(id, key), value);
          }
        }
      }
    } catch (error) {
      _log.w('Could not store extension secrets', error);
    }
  }

  // Installed extensions

  Future<({List<ExtensionInfo> extensions, Map<String, List<String>> priority})>
  list() => _call(PlatformBridge.listExtensions);

  Future<ExtensionPackagePreview> inspect(String path) =>
      _call(() => PlatformBridge.inspectExtensionPackage(path));

  Future<ExtensionInfo> install(String path, {bool allowDowngrade = false}) =>
      _call(() async {
        final info = await PlatformBridge.installExtension(
          path,
          allowDowngrade: allowDowngrade,
        );
        await _pushSecrets(info.manifest);
        return info;
      });

  Future<ExtensionInfo> installFolder(String path) => _call(() async {
    final info = await PlatformBridge.installExtensionFolder(path);
    await _pushSecrets(info.manifest);
    return info;
  });

  Future<ExtensionInfo> installFromRepository(
    String url,
    String id, {
    bool allowDowngrade = false,
  }) => _call(() async {
    final info = await PlatformBridge.installFromRepository(
      url,
      id,
      allowDowngrade: allowDowngrade,
    );
    await _pushSecrets(info.manifest);
    return info;
  });

  Future<void> uninstall(ExtensionInfo extension) => _call(() async {
    await PlatformBridge.uninstallExtension(extension.id);
    for (final setting in extension.manifest.secretSettings) {
      await secrets.delete(secretKey(extension.id, setting.key));
    }
  });

  Future<void> setEnabled(String id, bool enabled) =>
      _call(() => PlatformBridge.setExtensionEnabled(id, enabled));

  Future<void> setPriority(ExtensionCapability capability, List<String> ids) =>
      _call(() => PlatformBridge.setExtensionPriority(capability, ids));

  Future<void> setDeveloperMode(bool enabled) =>
      _call(() => PlatformBridge.setExtensionDeveloperMode(enabled));

  /// Secrets go to secure storage (and Rust's memory), the rest to Rust.
  Future<void> setSetting(
    ExtensionInfo extension,
    ExtensionSetting setting,
    Object? value,
  ) => _call(() async {
    if (setting.isSecret) {
      final text = value as String?;
      final key = secretKey(extension.id, setting.key);
      if (text == null || text.isEmpty) {
        await secrets.delete(key);
      } else {
        await secrets.write(key, text);
      }
    }
    await PlatformBridge.setExtensionSetting(extension.id, setting.key, value);
  });

  /// Runs a button's function. While it runs, login pages it asks for are
  /// opened with [openUrl]; the redirect comes back through
  /// [deliverCallbacks].
  Future<Object?> runAction(
    ExtensionInfo extension,
    ExtensionSetting button,
    Future<void> Function(String url) openUrl,
  ) => _call(() async {
    var running = true;
    final watcher = () async {
      while (running) {
        final request = await PlatformBridge.takeExtensionAuthRequest();
        if (request != null) {
          await openUrl(request.url);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }();
    try {
      return await PlatformBridge.invokeExtensionAction(
        extension.id,
        button.key,
      );
    } finally {
      running = false;
      await watcher;
    }
  });

  /// Hands login redirects Android received to the waiting extensions.
  Future<void> deliverCallbacks() async {
    final List<String> urls;
    try {
      urls = await PlatformBridge.takeExtensionCallbacks();
      if (urls.isEmpty) return;
      await start();
    } catch (error) {
      _log.w('Login callbacks unavailable', error);
      return;
    }
    for (final url in urls) {
      try {
        await PlatformBridge.extensionAuthCallback(url);
      } catch (error) {
        _log.w('Login callback was not accepted', error);
      }
    }
  }

  Future<ExtensionHealth> checkHealth(String id) =>
      _call(() => PlatformBridge.extensionHealth(id));

  Future<List<ExtensionLogEntry>> logs(String id) =>
      _call(() => PlatformBridge.extensionLogs(id));

  // Repositories

  Future<RepositoryPreview> previewRepository(String url) =>
      _call(() => PlatformBridge.previewRepository(url));

  Future<void> addRepository(RepositoryPreview preview) =>
      _call(() => PlatformBridge.addRepository(preview.url, preview.publicKey));

  Future<void> removeRepository(String url) =>
      _call(() => PlatformBridge.removeRepository(url));

  Future<List<RepositoryListing>> refreshRepositories() =>
      _call(PlatformBridge.refreshRepositories);

  // Lyrics (FEATURES 2.10, 2.11)

  static TrackQuery queryFor(Song song) => TrackQuery(
    title: song.title,
    artist: song.artist,
    album: song.album.isEmpty ? null : song.album,
    durationMs: song.durationMs,
    isrc: song.isrc,
    language: song.language,
  );

  Future<({List<LyricsCandidate> candidates, List<ExtensionFailure> errors})>
  searchLyrics(TrackQuery query) =>
      _call(() => PlatformBridge.searchLyrics(query));

  /// Imports [candidate] as the song's lyrics: fetched with `getLyrics`
  /// when it came without text, annotated for its language, saved as a new
  /// version with its source.
  Future<LyricDocument> importLyrics(
    int songId,
    LyricsCandidate candidate,
  ) async {
    final full = candidate.body != null
        ? candidate
        : await _call(
            () => PlatformBridge.getLyrics(candidate.extensionId, candidate.id),
          );
    final body = full.body;
    if (body == null || body.trim().isEmpty) {
      throw const ExtensionException('The extension returned no lyrics');
    }
    final parsed = LyricDocument.fromJson(
      await PlatformBridge.parseLyrics(
        body,
        format: full.format == 'elrc' ? 'elrc' : full.format,
      ),
    );
    if (parsed.isEmpty) throw const LyricsException('No lyric lines found');
    final language =
        candidate.language ??
        guessLyricsLanguage([for (final line in parsed.lines) line.text]);
    final annotated = await lyrics.annotate(parsed, language: language);
    return lyrics.save(
      songId,
      annotated.copyWith(
        source: () => LyricSource(
          extensionId: candidate.extensionId,
          itemId: candidate.id,
        ),
      ),
      source: 'extension',
    );
  }

  /// Fetches lyrics for a song that has none: the best candidate when it
  /// matches well enough. Returns whether lyrics were saved.
  Future<bool> autoFetchLyrics(Song song) async {
    try {
      final result = await searchLyrics(queryFor(song));
      final best = result.candidates.firstOrNull;
      // Below this the title or artist did not really match.
      if (best == null || best.score < 0.6) return false;
      await importLyrics(song.id, best);
      return true;
    } catch (error) {
      _log.w('Automatic lyric fetch failed', error);
      return false;
    }
  }

  // Metadata, artwork and audio (FEATURES 1.8, 6.2, 6.4, 6.6)

  Future<({List<TrackResult> tracks, List<ExtensionFailure> errors})>
  searchTracks(TrackQuery query) =>
      _call(() => PlatformBridge.searchMetadata(query));

  Future<TrackResult> track(String extensionId, String id) =>
      _call(() => PlatformBridge.getTrack(extensionId, id));

  String _requestId(String kind) =>
      'ext-$kind-${DateTime.now().microsecondsSinceEpoch}-${_requests++}';

  /// Downloads the best artwork for [track] into `covers/`; null when no
  /// extension has any.
  Future<String?> downloadArtwork(TrackResult track) async {
    try {
      final art = await _call(() => PlatformBridge.getArtwork(track.toJson()));
      final urls = [...art.urls, ?track.artworkUrl];
      final extensionId = art.extensionId ?? track.extensionId;
      if (urls.isEmpty) return null;
      final name = stableHash('${track.extensionId}\u0000${track.id}');
      final path = p.join(storage.covers.path, 'ext-$name.img');
      await storage.covers.create(recursive: true);
      await PlatformBridge.extensionDownload(
        extensionId: urls.first == track.artworkUrl
            ? track.extensionId
            : extensionId,
        url: urls.first,
        path: path,
        maxBytes: 10 << 20,
        requestId: _requestId('art'),
      );
      return path;
    } catch (error) {
      _log.w('Artwork download failed', error);
      return null;
    }
  }

  /// Adds [track] to the library as an extension song (streams until
  /// downloaded), or returns the one already added.
  Future<Song> addTrack(TrackResult track) async {
    final ref = ExtensionTrackRef.of(track);
    final existing = await library.songIdForTrack(ref);
    if (existing != null) return (await library.song(existing))!;
    final cover = await downloadArtwork(track);
    final id = await library.insertSong(
      NewSong(
        title: track.title,
        artist: track.artist,
        album: track.album ?? '',
        durationMs: track.durationMs,
        isrc: track.isrc,
        coverPath: cover,
        language: track.language,
        media: const [],
        extRef: ref,
      ),
    );
    await importer.refreshSearchKeys([id]);
    return (await library.song(id))!;
  }

  /// Applies [track]'s details (and artwork) to a library song (6.4).
  Future<void> applyDetails(Song song, TrackResult track) async {
    final cover = await downloadArtwork(track);
    await library.updateDetails(
      song.id,
      title: track.title,
      artist: track.artist.isEmpty ? null : track.artist,
      album: track.album,
      durationMs: song.media.isEmpty ? track.durationMs : null,
      isrc: track.isrc,
      language: track.language,
      coverPath: cover,
    );
    await importer.refreshSearchKeys([song.id]);
  }

  /// The extensions that can play [ref]: its own when it has audio, then
  /// the audio extensions in the user's order.
  Future<List<String>> _audioProviders(ExtensionTrackRef ref) async {
    final listed = await list();
    final enabled = {
      for (final extension in listed.extensions)
        if (extension.enabled &&
            extension.manifest.has(ExtensionCapability.audio))
          extension.id,
    };
    final ordered = listed.priority[ExtensionCapability.audio.name] ?? const [];
    return [
      if (enabled.contains(ref.extensionId)) ref.extensionId,
      for (final id in ordered)
        if (id != ref.extensionId && enabled.contains(id)) id,
    ];
  }

  /// Streams for an extension song, from the first audio extension that
  /// resolves it.
  Future<List<StreamSource>> resolveStreams(ExtensionTrackRef ref) async {
    Object? lastError;
    for (final extensionId in await _audioProviders(ref)) {
      try {
        final sources = await _call(
          () => PlatformBridge.resolveAudio(extensionId, ref.track),
        );
        return [
          for (final source in sources)
            StreamSource(
              extensionId: extensionId,
              source: source,
              cacheKey: cacheKey(extensionId, ref.trackId, source.kind),
            ),
        ];
      } catch (error) {
        lastError = error;
      }
    }
    throw ExtensionException(
      lastError == null
          ? 'No audio extension can play this song'
          : '$lastError',
    );
  }

  /// The stream cache name for one source of one track.
  static String cacheKey(String extensionId, String trackId, String kind) =>
      stableHash('$extensionId\u0000$trackId\u0000$kind');

  /// 128 bits of FNV-1a over [text] as hex: a stable file name, not a
  /// security measure.
  static String stableHash(String text) {
    final bytes = utf8.encode(text);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    String fnv(String offset) {
      var hash = BigInt.parse(offset, radix: 16);
      for (final byte in bytes) {
        hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
      }
      return hash.toRadixString(16).padLeft(16, '0');
    }

    return fnv('cbf29ce484222325') + fnv('84222325cbf29ce4');
  }

  /// Downloads an extension song's audio into the library (FEATURES 6.6):
  /// every source the extension resolves becomes a media file, and lyrics
  /// are fetched when the song has none. Afterwards it plays offline.
  Future<void> download(Song song, {bool fetchLyrics = true}) async {
    final ref = song.extRef;
    if (ref == null) throw const ExtensionException('Not an extension song');
    final streams = await resolveStreams(ref);
    try {
      for (final stream in streams) {
        final kind =
            MediaKind.values.asNameMap()[stream.source.kind] ??
            MediaKind.original;
        final ext = stream.source.format ?? _extensionOf(stream.source.url);
        await storage.importStaging.create(recursive: true);
        final staged = p.join(
          storage.importStaging.path,
          '${DateTime.now().microsecondsSinceEpoch}_${kind.name}.$ext',
        );
        await PlatformBridge.extensionDownload(
          extensionId: stream.extensionId,
          url: stream.source.url,
          headers: stream.source.headers,
          path: staged,
          cacheKey: stream.cacheKey,
          requestId: _requestId('download'),
        );
        final stored = await importer.storeMedia(
          StagedFile(name: p.basename(staged), path: staged),
          kind,
        );
        final file = stored.file;
        await library.setMedia(
          song.id,
          NewMediaFile(
            kind: file.kind,
            path: file.path,
            sha256: file.sha256,
            bytes: file.bytes,
            codec: file.codec,
            sampleRate: file.sampleRate,
            source: 'extension',
          ),
        );
        if (song.durationMs == null && stored.durationMs != null) {
          await library.updateDetails(song.id, durationMs: stored.durationMs);
        }
      }
    } finally {
      await importer.discardStaging();
    }
    if (fetchLyrics && await library.lyrics(song.id) == null) {
      await autoFetchLyrics(song);
    }
  }

  static String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return audioExtensions.contains(ext) ? ext : 'audio';
  }

  // Backups (DATA_MODEL.md §3: extensions.json + extensions/*.kalaoext)

  /// `extensions.json` for a backup and the package files to include.
  Future<({Map<String, Object?> json, Map<String, String> packages})>
  backupState() async {
    final listed = await list();
    final repositories = await _call(PlatformBridge.listRepositories);
    return (
      json: <String, Object?>{
        'version': 1,
        'extensions': [
          for (final extension in listed.extensions)
            {
              'id': extension.id,
              'version': extension.manifest.version,
              'enabled': extension.enabled,
              'source': extension.sourceKind,
              'repository': extension.repository,
              'settings': extension.settings,
              'package': 'extensions/${extension.id}.kalaoext',
            },
        ],
        'priority': listed.priority,
        'repositories': [
          for (final repository in repositories) repository.toJson(),
        ],
      },
      packages: {
        for (final extension in listed.extensions)
          'extensions/${extension.id}.kalaoext': extension.packagePath,
      },
    );
  }

  /// Installs the extensions of an extracted backup in [dir] and restores
  /// their state. Secrets were never in the backup: extensions that need
  /// them show it and ask again (FEATURES 7.5). Returns how many installed.
  Future<int> restoreBackup(Directory dir, Map<String, dynamic> json) async {
    var restored = 0;
    for (final repository in json['repositories'] as List<dynamic>? ?? []) {
      final record = (repository as Map).cast<String, dynamic>();
      try {
        await _call(
          () => PlatformBridge.addRepository(
            record['url'] as String,
            record['publicKey'] as String,
            name: record['name'] as String?,
            fetch: false,
          ),
        );
      } catch (error) {
        _log.w('Repository from the backup not restored', error);
      }
    }
    for (final entry in json['extensions'] as List<dynamic>? ?? []) {
      final item = (entry as Map).cast<String, dynamic>();
      // The package path is derived from the id, never taken from the JSON;
      // Rust checks the id and the package again on install.
      final id = item['id'] as String? ?? '';
      if (!RegExp(r'^[a-z0-9.\-]+$').hasMatch(id)) continue;
      final package = File(p.join(dir.path, 'extensions', '$id.kalaoext'));
      if (!package.existsSync()) continue;
      try {
        final info = await install(package.path, allowDowngrade: false);
        restored++;
        for (final MapEntry(:key, :value)
            in ((item['settings'] as Map?) ?? const {}).entries) {
          await _call(
            () => PlatformBridge.setExtensionSetting(info.id, '$key', value),
          );
        }
        if (item['enabled'] == false) await setEnabled(info.id, false);
      } catch (error) {
        // An installed newer version stays.
        _log.w('Extension ${item['id']} from the backup not restored', error);
      }
    }
    for (final MapEntry(:key, :value)
        in ((json['priority'] as Map?) ?? const {}).entries) {
      final capability = ExtensionCapability.values.asNameMap()['$key'];
      if (capability == null) continue;
      await setPriority(capability, [
        for (final id in value as List<dynamic>) '$id',
      ]);
    }
    return restored;
  }
}
