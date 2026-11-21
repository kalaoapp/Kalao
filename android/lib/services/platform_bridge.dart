// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/services/backend/backend_channel.dart';

/// Backend info reported by `getBackendInfo`.
@immutable
class BackendInfo {
  const BackendInfo({
    required this.name,
    required this.version,
    required this.os,
    required this.arch,
    required this.initialized,
    required this.methods,
  });

  factory BackendInfo.fromJson(Map<String, dynamic> json) => BackendInfo(
    name: json['name'] as String? ?? '',
    version: json['version'] as String? ?? '',
    os: json['os'] as String? ?? '',
    arch: json['arch'] as String? ?? '',
    initialized: json['initialized'] as bool? ?? false,
    methods: [
      for (final method in json['methods'] as List<dynamic>? ?? const [])
        method as String,
    ],
  );

  final String name;
  final String version;
  final String os;
  final String arch;
  final bool initialized;
  final List<String> methods;
}

/// One entry from the Rust log buffer.
@immutable
class NativeLogEntry {
  const NativeLogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  factory NativeLogEntry.fromJson(Map<String, dynamic> json) => NativeLogEntry(
    timestamp: json['timestamp'] as String? ?? '',
    level: json['level'] as String? ?? 'INFO',
    tag: json['tag'] as String? ?? 'Rust',
    message: json['message'] as String? ?? '',
  );

  final String timestamp;
  final String level;
  final String tag;
  final String message;
}

/// A page of Rust log entries and the index to request next.
@immutable
class NativeLogPage {
  const NativeLogPage(this.entries, this.nextIndex);

  final List<NativeLogEntry> entries;
  final int nextIndex;
}

/// A file in a SAF folder.
@immutable
class DocumentEntry {
  const DocumentEntry({
    required this.uri,
    required this.name,
    this.bytes = 0,
    this.modified,
  });

  factory DocumentEntry.fromMap(Map<String, Object?> map) => DocumentEntry(
    uri: map['uri'] as String? ?? '',
    name: map['name'] as String? ?? '',
    bytes: (map['bytes'] as num?)?.toInt() ?? 0,
    modified: switch (map['modified']) {
      final num ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(
        ms.toInt(),
      ),
      _ => null,
    },
  );

  final String uri;
  final String name;
  final int bytes;
  final DateTime? modified;
}

/// A file under a music folder, as `listLibraryFolder` reports it. [dir] is
/// its folder below the granted one (`''` at the top); [modified] is the
/// provider's modification time in milliseconds (0 when unknown).
@immutable
class FolderEntry {
  const FolderEntry({
    required this.uri,
    required this.name,
    this.dir = '',
    this.bytes = 0,
    this.modified = 0,
  });

  factory FolderEntry.fromMap(Map<String, Object?> map) => FolderEntry(
    uri: map['uri'] as String? ?? '',
    name: map['name'] as String? ?? '',
    dir: map['dir'] as String? ?? '',
    bytes: (map['bytes'] as num?)?.toInt() ?? 0,
    modified: (map['modified'] as num?)?.toInt() ?? 0,
  );

  final String uri;
  final String name;
  final String dir;
  final int bytes;
  final int modified;
}

/// A document opened for reading: [path] (`/proc/self/fd/<n>`) opens like a
/// file until [handle] is closed with [PlatformBridge.closeDocuments].
typedef OpenedDocument = ({String path, int handle});

/// The only caller of the backend. Every method is a typed wrapper over one
/// channel call. Rust methods take their arguments as JSON text (Kotlin passes
/// it through unchanged) and reply with JSON text, decoded off the UI isolate
/// when large; `__json_file` spill replies are read and deleted here.
class PlatformBridge {
  PlatformBridge._();

  static const _jsonResultFileKey = '__json_file';
  static const _backgroundJsonDecodeThresholdBytes = 64 * 1024;

  // Lifecycle and diagnostics (Rust)

  static Future<BackendInfo> getBackendInfo() async =>
      BackendInfo.fromJson(await _requiredMap('getBackendInfo'));

  static Future<NativeLogPage> getLogs({int sinceIndex = 0}) async {
    final json = await _requiredMap('getLogs', {'sinceIndex': sinceIndex});
    return NativeLogPage([
      for (final entry in json['logs'] as List<dynamic>? ?? const [])
        NativeLogEntry.fromJson((entry as Map<dynamic, dynamic>).cast()),
    ], (json['next_index'] as num?)?.toInt() ?? sinceIndex);
  }

  static Future<void> clearLogs() => _rust('clearLogs');

  static Future<void> setLoggingEnabled(bool enabled) =>
      _rust('setLoggingEnabled', {'enabled': enabled});

  // Player (Rust engine)

  /// Loads [sources] (`kind` → file path) and [streams] (sources an
  /// extension resolved, FEATURES 1.8) paused at [start].
  static Future<EnginePlayerState> playerLoad({
    required String songId,
    Map<String, String> sources = const {},
    List<StreamSource> streams = const [],
    Duration start = Duration.zero,
  }) => _player('playerLoad', {
    'songId': songId,
    'sources': [
      for (final entry in sources.entries)
        {'kind': entry.key, 'path': entry.value},
      for (final stream in streams) stream.toJson(),
    ],
    'startMs': start.inMilliseconds,
  });

  static Future<EnginePlayerState> playerPlay() => _player('playerPlay');

  static Future<EnginePlayerState> playerPause() => _player('playerPause');

  static Future<EnginePlayerState> playerStop() => _player('playerStop');

  static Future<EnginePlayerState> playerSeek(Duration position) =>
      _player('playerSeek', {'ms': position.inMilliseconds});

  static Future<EnginePlayerState> playerSetVolume(double volume) =>
      _player('playerSetVolume', {'volume': volume});

  /// [vocals] is the vocal-guide level (0–1); [instrumental] the backing level.
  static Future<EnginePlayerState> playerSetStemGains({
    double? vocals,
    double? instrumental,
  }) => _player('playerSetStemGains', {
    'vocals': ?vocals,
    'instrumental': ?instrumental,
  });

  /// Transposes by [semitones] (±6) without changing the tempo.
  static Future<EnginePlayerState> playerSetKey(double semitones) =>
      _player('playerSetKey', {'semitones': semitones});

  /// Repeats [start]..[end] of the song; both null clears the loop.
  static Future<EnginePlayerState> playerSetLoop({
    Duration? start,
    Duration? end,
  }) => _player('playerSetLoop', {
    'startMs': ?start?.inMilliseconds,
    'endMs': ?end?.inMilliseconds,
  });

  /// Playback speed 0.5–1.5 (1 = normal) at the same pitch.
  static Future<EnginePlayerState> playerSetTempo(double rate) =>
      _player('playerSetTempo', {'rate': rate});

  /// `original` or `instrumental`, with a short crossfade.
  static Future<EnginePlayerState> playerSwitchTrack(String kind) =>
      _player('playerSwitchTrack', {'kind': kind});

  static Future<EnginePlayerState> playerState() => _player('playerState');

  static Future<EnginePlayerState> _player(
    String method, [
    Map<String, Object?>? args,
  ]) async => EnginePlayerState.fromJson(await _requiredMap(method, args));

  // Import and lyrics (Rust)

  /// Tags, duration, codec and decodability; writes embedded art to
  /// [coverBase] + extension when given (reply `coverPath`).
  static Future<Map<String, dynamic>> probeAudio(
    String path, {
    String? coverBase,
  }) => _requiredMap('probeAudio', {'path': path, 'coverBase': ?coverBase});

  /// Proposals `{original, instrumental?, lyrics?, title}` over [files]
  /// (`{name, durationMs?}`), as indices.
  static Future<List<Map<String, dynamic>>> pairImportFiles(
    List<Map<String, Object?>> files,
  ) => _requiredList('pairImportFiles', {'files': files});

  /// A lyric document from LRC, enhanced LRC, TTML or plain text ([format]
  /// `lrc`/`elrc`/`ttml`/`plain`, or null to detect).
  static Future<Map<String, dynamic>> parseLyrics(
    String raw, {
    String? format,
  }) => _requiredMap('parseLyrics', {'raw': raw, 'format': ?format});

  /// [doc] (a lyric document as JSON) as `lrc` or `elrc` text.
  static Future<String> exportLyrics(
    Map<String, Object?> doc,
    String format,
  ) async =>
      (await _requiredMap('exportLyrics', {
            'doc': doc,
            'format': format,
          }))['text']
          as String? ??
      '';

  /// [texts] in the Chinese variant [to] (`s2t`, `s2tw`, `s2hk`, `t2s`).
  static Future<List<String>> convertChinese(
    List<String> texts,
    String to,
  ) async {
    final decoded = await _rust('convertChinese', {'texts': texts, 'to': to});
    if (decoded is! List) {
      throw FormatException(
        'Expected list result from convertChinese, got ${decoded.runtimeType}',
      );
    }
    return [for (final text in decoded) text as String];
  }

  /// The lyrics' language (`ja` when a line has kana, `zh` when one has Han
  /// characters, else null) and layers `{lineIndex, kind, origin, segments}`
  /// for [lines]: [layers] (`pinyin`, `furigana`, `romaji`), or when null
  /// the ones for that language.
  static Future<({String? sourceLang, List<Map<String, dynamic>> layers})>
  annotateLyrics(List<String> lines, {List<String>? layers}) async {
    final reply = await _requiredMap('annotateLyrics', {
      'lines': lines,
      'layers': ?layers,
    });
    return (
      sourceLang: reply['sourceLang'] as String?,
      layers: [
        for (final layer in reply['layers'] as List<dynamic>? ?? const [])
          (layer as Map).cast<String, dynamic>(),
      ],
    );
  }

  /// Hashes and probes a staged import file in one job (`probe` is null when
  /// Symphonia cannot read it).
  static Future<({String sha256, Map<String, dynamic>? probe})> importInspect(
    String path, {
    required String requestId,
  }) async {
    final reply = await runNativeDataJob({
      'operation': 'importInspect',
      'path': path,
    }, requestId: requestId);
    return (
      sha256: reply['sha256'] as String,
      probe: (reply['probe'] as Map?)?.cast<String, dynamic>(),
    );
  }

  /// Moves a staged file to `mediaDir/<sha256>.<ext>` (or drops it when the
  /// library already has that file) and probes it there, writing its cover
  /// to [coverBase] + extension when given.
  static Future<({String path, int bytes, Map<String, dynamic>? probe})>
  importStore({
    required String path,
    required String sha256,
    required String mediaDir,
    String? coverBase,
    required String requestId,
  }) async {
    final reply = await runNativeDataJob({
      'operation': 'importStore',
      'path': path,
      'sha256': sha256,
      'mediaDir': mediaDir,
      'coverBase': ?coverBase,
    }, requestId: requestId);
    return (
      path: reply['path'] as String,
      bytes: (reply['bytes'] as num?)?.toInt() ?? 0,
      probe: (reply['probe'] as Map?)?.cast<String, dynamic>(),
    );
  }

  static Future<String> hashFile(
    String path, {
    required String requestId,
  }) async =>
      (await runNativeDataJob({
            'operation': 'hash_file',
            'path': path,
          }, requestId: requestId))['sha256']
          as String;

  /// `song_search` rows for [songs] (`{id, title, artist}`).
  static Future<List<Map<String, dynamic>>> rebuildSearchKeys(
    List<Map<String, Object?>> songs, {
    required String requestId,
  }) async {
    final reply = await runNativeDataJob({
      'operation': 'rebuildSearchKeys',
      'songs': songs,
    }, requestId: requestId);
    return [
      for (final row in reply['rows'] as List<dynamic>? ?? const [])
        (row as Map).cast<String, dynamic>(),
    ];
  }

  /// Writes a `.kalaobackup` archive of [entries] (`{name, path}`) to
  /// [output]; Rust adds each entry's SHA-256 to [manifest].
  static Future<Map<String, dynamic>> backupWrite({
    required String output,
    required List<Map<String, String>> entries,
    required Map<String, Object?> manifest,
    required String requestId,
  }) => runNativeDataJob({
    'operation': 'backupWrite',
    'output': output,
    'entries': entries,
    'manifest': manifest,
  }, requestId: requestId);

  /// Checks the archive at [path] (names, sizes, checksums, format at most
  /// [maxFormat]), extracts it into [extractTo] and returns its manifest.
  static Future<Map<String, dynamic>> backupInspect({
    required String path,
    required String extractTo,
    required int maxFormat,
    required String requestId,
  }) => runNativeDataJob({
    'operation': 'backupInspect',
    'path': path,
    'extractTo': extractTo,
    'maxFormat': maxFormat,
  }, requestId: requestId);

  /// Saves [url] (through extension [extensionId]'s network session, or its
  /// finished stream cache [cacheKey]) to [path]; at most [maxBytes].
  static Future<({String path, int bytes})> extensionDownload({
    required String extensionId,
    required String url,
    Map<String, String> headers = const {},
    required String path,
    String? cacheKey,
    int? maxBytes,
    required String requestId,
  }) async {
    final reply = await runNativeDataJob({
      'operation': 'extensionDownload',
      'extensionId': extensionId,
      'url': url,
      'headers': headers,
      'path': path,
      'cacheKey': ?cacheKey,
      'maxBytes': ?maxBytes,
    }, requestId: requestId);
    return (
      path: reply['path'] as String? ?? path,
      bytes: (reply['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Runs CPU or file work in the Rust worker. [requestId] lets
  /// [cancelNativeDataJob] cancel it, also before it starts.
  static Future<Map<String, dynamic>> runNativeDataJob(
    Map<String, Object?> request, {
    required String requestId,
  }) async {
    final result = await backendChannel.invokeMethod<Object?>(
      'runNativeDataJob',
      {'request_id': requestId, 'request_json': jsonEncode(request)},
    );
    return _asMap(await decodeJsonResult(result), 'runNativeDataJob');
  }

  static Future<void> cancelNativeDataJob(String requestId) => backendChannel
      .invokeMethod<void>('cancelNativeDataJob', {'request_id': requestId});

  // Extensions (Rust, kalao-extensions)

  /// Opens the installed extensions under [root]; streams cache in
  /// [streamCache]. Returns the installed list.
  static Future<List<ExtensionInfo>> extensionsInit({
    required String root,
    required String streamCache,
    required String appVersion,
    required bool developerMode,
  }) async => _extensions(
    (await _requiredMap('extensionsInit', {
      'root': root,
      'streamCache': streamCache,
      'appVersion': appVersion,
      'developerMode': developerMode,
    }))['extensions'],
  );

  static List<ExtensionInfo> _extensions(Object? list) => [
    for (final item in list as List<dynamic>? ?? const [])
      ExtensionInfo.fromJson((item as Map).cast()),
  ];

  /// Installed extensions and the priority order per capability.
  static Future<
    ({List<ExtensionInfo> extensions, Map<String, List<String>> priority})
  >
  listExtensions() async {
    final reply = await _requiredMap('listExtensions');
    return (
      extensions: _extensions(reply['extensions']),
      priority: {
        for (final MapEntry(:key, :value)
            in ((reply['priority'] as Map?) ?? const {}).entries)
          '$key': [for (final id in value as List<dynamic>) '$id'],
      },
    );
  }

  static Future<ExtensionPackagePreview> inspectExtensionPackage(
    String path,
  ) async => ExtensionPackagePreview.fromJson(
    await _requiredMap('inspectExtensionPackage', {'path': path}),
  );

  static Future<ExtensionInfo> installExtension(
    String path, {
    bool allowDowngrade = false,
  }) async => ExtensionInfo.fromJson(
    await _requiredMap('installExtension', {
      'path': path,
      'allowDowngrade': allowDowngrade,
    }),
  );

  /// Developer mode: packs and installs a folder (again = reload).
  static Future<ExtensionInfo> installExtensionFolder(String path) async =>
      ExtensionInfo.fromJson(
        await _requiredMap('installExtensionFolder', {'path': path}),
      );

  static Future<void> uninstallExtension(String id) =>
      _rust('uninstallExtension', {'id': id});

  static Future<void> setExtensionEnabled(String id, bool enabled) =>
      _rust('setExtensionEnabled', {'id': id, 'enabled': enabled});

  static Future<void> setExtensionPriority(
    ExtensionCapability capability,
    List<String> ids,
  ) => _rust('setExtensionPriority', {
    'capability': capability.name,
    'ids': ids,
  });

  /// A plain setting is stored by Rust; a secret is only held in memory
  /// (the caller keeps it in secure storage).
  static Future<void> setExtensionSetting(
    String id,
    String key,
    Object? value,
  ) => _rust('setExtensionSetting', {'id': id, 'key': key, 'value': value});

  static Future<void> setExtensionSecrets(
    String id,
    Map<String, String> values,
  ) => _rust('setExtensionSecrets', {'id': id, 'values': values});

  /// Secrets extensions set since the last call: id → key → value (null
  /// deletes).
  static Future<Map<String, Map<String, String?>>>
  takeExtensionSecretUpdates() async {
    final reply = await _requiredMap('takeExtensionSecretUpdates');
    return {
      for (final MapEntry(:key, :value) in reply.entries)
        key: {
          for (final MapEntry(key: name, value: secret)
              in (value as Map).cast<String, Object?>().entries)
            name: secret as String?,
        },
    };
  }

  static Future<void> setExtensionDeveloperMode(bool enabled) =>
      _rust('setExtensionDeveloperMode', {'enabled': enabled});

  /// Runs a `button` setting's function (may wait for a login callback).
  static Future<Object?> invokeExtensionAction(String id, String key) async =>
      (await _requiredMap('invokeExtensionAction', {
        'id': id,
        'key': key,
      }))['result'];

  /// The next login page an extension asked to open, or null.
  static Future<({String extensionId, String url})?>
  takeExtensionAuthRequest() async {
    final reply = await _rust('takeExtensionAuthRequest');
    if (reply case {'extensionId': final String id, 'url': final String url}) {
      return (extensionId: id, url: url);
    }
    return null;
  }

  /// Hands a `kalao://ext/<id>/…` redirect to the waiting extension.
  static Future<void> extensionAuthCallback(String url) =>
      _rust('extensionAuthCallback', {'url': url});

  static Future<ExtensionHealth> extensionHealth(String id) async =>
      ExtensionHealth.fromJson(
        await _requiredMap('extensionHealth', {'id': id}),
      );

  static Future<List<ExtensionLogEntry>> extensionLogs(String id) async => [
    for (final entry
        in (await _requiredMap('extensionLogs', {'id': id}))['logs']
                as List<dynamic>? ??
            const [])
      ExtensionLogEntry.fromJson((entry as Map).cast()),
  ];

  static Future<List<ExtensionRepository>> listRepositories() async => [
    for (final item in await _requiredList('listRepositories'))
      ExtensionRepository.fromJson(item),
  ];

  static Future<RepositoryPreview> previewRepository(String url) async =>
      RepositoryPreview.fromJson(
        await _requiredMap('previewRepository', {'url': url}),
      );

  /// Trusts [publicKey] for [url]. [fetch] false restores a repository
  /// from a backup without the network.
  static Future<void> addRepository(
    String url,
    String publicKey, {
    String? name,
    bool fetch = true,
  }) => _rust('addRepository', {
    'url': url,
    'publicKey': publicKey,
    'name': ?name,
    'fetch': fetch,
  });

  static Future<void> removeRepository(String url) =>
      _rust('removeRepository', {'url': url});

  static Future<List<RepositoryListing>> refreshRepositories({
    String? url,
  }) async => [
    for (final item
        in (await _requiredMap('refreshRepositories', {
                  'url': ?url,
                }))['repositories']
                as List<dynamic>? ??
            const [])
      RepositoryListing.fromJson((item as Map).cast()),
  ];

  static Future<ExtensionInfo> installFromRepository(
    String url,
    String id, {
    bool allowDowngrade = false,
  }) async => ExtensionInfo.fromJson(
    await _requiredMap('installFromRepository', {
      'url': url,
      'id': id,
      'allowDowngrade': allowDowngrade,
    }),
  );

  /// Ranked candidates from every enabled lyrics extension.
  static Future<
    ({List<LyricsCandidate> candidates, List<ExtensionFailure> errors})
  >
  searchLyrics(TrackQuery query) async {
    final reply = await _requiredMap('searchLyrics', {'query': query.toJson()});
    return (
      candidates: [
        for (final item in reply['candidates'] as List<dynamic>? ?? const [])
          LyricsCandidate.fromJson((item as Map).cast()),
      ],
      errors: extensionFailures(reply['errors']),
    );
  }

  static Future<LyricsCandidate> getLyrics(
    String extensionId,
    String id,
  ) async => LyricsCandidate.fromJson(
    await _requiredMap('getLyrics', {'extensionId': extensionId, 'id': id}),
  );

  /// Merged tracks from every enabled metadata extension.
  static Future<({List<TrackResult> tracks, List<ExtensionFailure> errors})>
  searchMetadata(TrackQuery query) async {
    final reply = await _requiredMap('searchMetadata', {
      'query': query.toJson(),
    });
    return (
      tracks: [
        for (final item in reply['tracks'] as List<dynamic>? ?? const [])
          TrackResult.fromJson((item as Map).cast()),
      ],
      errors: extensionFailures(reply['errors']),
    );
  }

  static Future<TrackResult> getTrack(String extensionId, String id) async =>
      TrackResult.fromJson(
        await _requiredMap('getTrack', {'extensionId': extensionId, 'id': id}),
      );

  /// Image URLs for [track], widest first.
  static Future<({String? extensionId, List<String> urls})> getArtwork(
    Map<String, Object?> track, {
    String? extensionId,
  }) async {
    final reply = await _requiredMap('getArtwork', {
      'track': track,
      'extensionId': ?extensionId,
    });
    final images = [
      for (final image in reply['images'] as List<dynamic>? ?? const [])
        (
          url: (image as Map)['url'] as String,
          width: (image['width'] as num?)?.toInt() ?? 0,
        ),
    ]..sort((a, b) => b.width.compareTo(a.width));
    return (
      extensionId: reply['extensionId'] as String?,
      urls: [for (final image in images) image.url],
    );
  }

  static Future<List<AudioSourceRef>> resolveAudio(
    String extensionId,
    Map<String, Object?> track,
  ) async => [
    for (final source
        in (await _requiredMap('resolveAudio', {
                  'extensionId': extensionId,
                  'track': track,
                }))['sources']
                as List<dynamic>? ??
            const [])
      AudioSourceRef.fromJson((source as Map).cast()),
  ];

  // Android-native methods

  static Future<int> getAndroidSdkVersion() async =>
      await backendChannel.invokeMethod<int>('getAndroidSdkVersion') ?? 0;

  static Future<void> setScreenAwake(bool enabled) =>
      backendChannel.invokeMethod<void>('setScreenAwake', {'enabled': enabled});

  /// Starts (or retitles) foreground work of [kind]. Returns false when
  /// Android refused the foreground service; the work then runs anyway.
  static Future<bool> startBackgroundWork({
    required String kind,
    required String title,
    String text = '',
  }) async =>
      await backendChannel.invokeMethod<bool>('startBackgroundWork', {
        'kind': kind,
        'title': title,
        'text': text,
      }) ??
      false;

  /// [progress] is a percentage, or negative for indeterminate.
  static Future<void> updateBackgroundWork({
    required String kind,
    required String title,
    String text = '',
    int progress = -1,
  }) => backendChannel.invokeMethod<void>('updateBackgroundWork', {
    'kind': kind,
    'title': title,
    'text': text,
    'progress': progress,
  });

  static Future<void> stopBackgroundWork(String kind) =>
      backendChannel.invokeMethod<void>('stopBackgroundWork', {'kind': kind});

  // Storage Access Framework (backups)

  /// Asks where to save [name]; the document URI, or null when cancelled.
  static Future<String?> createDocument(String name) =>
      backendChannel.invokeMethod<String>('createDocument', {'name': name});

  /// Asks for a folder and keeps access to it; its tree URI, or null.
  static Future<String?> pickDocumentTree() =>
      backendChannel.invokeMethod<String>('pickDocumentTree');

  static Future<void> copyFileToDocument(String path, String uri) =>
      backendChannel.invokeMethod<void>('copyFileToDocument', {
        'path': path,
        'uri': uri,
      });

  /// Copies [path] into the folder [treeUri] as [name]; the new document URI.
  static Future<String> writeFileToTree({
    required String treeUri,
    required String name,
    required String path,
  }) async =>
      await backendChannel.invokeMethod<String>('writeFileToTree', {
        'treeUri': treeUri,
        'name': name,
        'path': path,
      }) ??
      '';

  /// The files in the folder [treeUri].
  static Future<List<DocumentEntry>> listDocumentTree(String treeUri) async {
    final rows =
        await backendChannel.invokeMethod<List<Object?>>('listDocumentTree', {
          'treeUri': treeUri,
        }) ??
        const [];
    return [
      for (final row in rows)
        DocumentEntry.fromMap((row! as Map).cast<String, Object?>()),
    ];
  }

  static Future<bool> deleteDocument(String uri) async =>
      await backendChannel.invokeMethod<bool>('deleteDocument', {'uri': uri}) ??
      false;

  /// Every audio and lyrics file under the music folder [treeUri], or null
  /// when Kalao no longer has access to it.
  static Future<List<FolderEntry>?> listLibraryFolder(String treeUri) async {
    final rows = await backendChannel.invokeMethod<List<Object?>>(
      'listLibraryFolder',
      {'treeUri': treeUri},
    );
    return rows == null
        ? null
        : [
            for (final row in rows)
              FolderEntry.fromMap((row! as Map).cast<String, Object?>()),
          ];
  }

  /// Opens the document [uri] for reading (a music-folder file).
  static Future<OpenedDocument> openDocument(String uri) async {
    final reply = await backendChannel.invokeMethod<Map<Object?, Object?>>(
      'openDocument',
      {'uri': uri},
    );
    if (reply case {'path': final String path, 'handle': final int handle}) {
      return (path: path, handle: handle);
    }
    throw StateError('openDocument returned no descriptor for $uri');
  }

  static Future<void> closeDocuments(List<int> handles) => handles.isEmpty
      ? Future.value()
      : backendChannel.invokeMethod<void>('closeDocuments', {
          'handles': handles,
        });

  /// Gives up the persisted access to [treeUri].
  static Future<void> releaseDocumentTree(String treeUri) => backendChannel
      .invokeMethod<void>('releaseDocumentTree', {'treeUri': treeUri});

  /// Files opened with or shared to Kalao since the last call, as cache
  /// copies `{path, name}` (the caller deletes them).
  static Future<List<({String path, String name})>> takeSharedFiles() async {
    final rows =
        await backendChannel.invokeMethod<List<Object?>>('takeSharedFiles') ??
        const [];
    return [
      for (final row in rows)
        if (row case {'path': final String path, 'name': final String name})
          (path: path, name: name),
    ];
  }

  /// `kalao://ext/…` login redirects received since the last call.
  static Future<List<String>> takeExtensionCallbacks() async => [
    for (final url
        in await backendChannel.invokeMethod<List<Object?>>(
              'takeExtensionCallbacks',
            ) ??
            const <Object?>[])
      url! as String,
  ];

  /// The device's ABIs, preferred first (`arm64-v8a`, …).
  static Future<List<String>> getSupportedAbis() async => [
    for (final abi
        in await backendChannel.invokeMethod<List<Object?>>(
              'getSupportedAbis',
            ) ??
            const <Object?>[])
      abi! as String,
  ];

  /// Opens the system installer for a verified update APK. False when the
  /// user first has to allow Kalao to install apps (Settings was opened).
  static Future<bool> installApk(String path) async =>
      await backendChannel.invokeMethod<bool>('installApk', {'path': path}) ??
      false;

  /// The last native crash report as JSON text, or null.
  static Future<String?> readLastCrashReport() =>
      backendChannel.invokeMethod<String>('readLastCrashReport');

  static Future<void> clearLastCrashReport() =>
      backendChannel.invokeMethod<void>('clearLastCrashReport');

  static Future<void> recordAppRuntimeError({
    required String error,
    required String stack,
    required String logs,
  }) => backendChannel.invokeMethod<void>('recordAppRuntimeError', {
    'error': error,
    'stack': stack,
    'logs': logs,
  });

  // Decoding

  /// Calls a Rust method with [args] as JSON text; the decoded reply.
  static Future<Object?> _rust(
    String method, [
    Map<String, Object?>? args,
  ]) async => decodeJsonResult(
    await backendChannel.invokeMethod<Object?>(
      method,
      jsonEncode(args ?? const <String, Object?>{}),
    ),
  );

  static Future<Map<String, dynamic>> _requiredMap(
    String method, [
    Map<String, Object?>? args,
  ]) async => _asMap(await _rust(method, args), method);

  static Future<List<Map<String, dynamic>>> _requiredList(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final decoded = await _rust(method, args);
    if (decoded is! List) {
      throw FormatException(
        'Expected list result from $method, got ${decoded.runtimeType}',
      );
    }
    return [for (final item in decoded) (item as Map).cast<String, dynamic>()];
  }

  static Map<String, dynamic> _asMap(Object? decoded, String method) {
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException(
      'Expected map result from $method, got ${decoded.runtimeType}',
    );
  }

  /// Decodes a channel reply: JSON text, or a `{"__json_file": path}` spill
  /// that is read in a background isolate and then deleted.
  @visibleForTesting
  static Future<Object?> decodeJsonResult(Object? result) async {
    if (result is Map && result[_jsonResultFileKey] is String) {
      final file = File(result[_jsonResultFileKey] as String);
      try {
        return await compute(_decodeJsonFile, file.path);
      } finally {
        try {
          await file.delete();
        } on FileSystemException {
          // Already gone; the host sweeps stale spill files at startup.
        }
      }
    }
    if (result is String) {
      if (result.isEmpty) return null;
      if (result.length >= _backgroundJsonDecodeThresholdBytes) {
        return compute(_decodeJson, result);
      }
      return jsonDecode(result);
    }
    return result;
  }
}

Object? _decodeJson(String json) => jsonDecode(json);

Object? _decodeJsonFile(String path) =>
    jsonDecode(File(path).readAsStringSync());
