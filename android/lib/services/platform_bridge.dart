// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// The only caller of the backend. Every method is a typed wrapper over one
/// channel call; JSON replies are decoded off the UI isolate when large, and
/// `__json_file` spill replies are read and deleted here.
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

  static Future<void> clearLogs() => _invoke('clearLogs');

  static Future<void> setLoggingEnabled(bool enabled) =>
      _invoke('setLoggingEnabled', {'enabled': enabled});

  // Player (Rust engine)

  /// Loads [sources] (`kind` → file path) paused at [start].
  static Future<EnginePlayerState> playerLoad({
    required String songId,
    required Map<String, String> sources,
    Duration start = Duration.zero,
  }) => _player('playerLoad', {
    'songId': songId,
    'sources': [
      for (final entry in sources.entries)
        {'kind': entry.key, 'path': entry.value},
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
    final decoded = await decodeJsonResult(
      await backendChannel.invokeMethod<Object?>('convertChinese', {
        'texts': texts,
        'to': to,
      }),
    );
    if (decoded is! List) {
      throw FormatException(
        'Expected list result from convertChinese, got ${decoded.runtimeType}',
      );
    }
    return [for (final text in decoded) text as String];
  }

  /// Layers `{lineIndex, kind, origin, segments}` for [lines] ([layers] from
  /// `pinyin`, `furigana`, `romaji`).
  static Future<List<Map<String, dynamic>>> annotateLyrics(
    List<String> lines, {
    List<String> layers = const ['pinyin'],
  }) => _requiredList('annotateLyrics', {'lines': lines, 'layers': layers});

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

  static Future<void> _invoke(String method, [Map<String, Object?>? args]) =>
      backendChannel.invokeMethod<Object?>(method, args);

  static Future<Map<String, dynamic>> _requiredMap(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final result = await backendChannel.invokeMethod<Object?>(method, args);
    return _asMap(await decodeJsonResult(result), method);
  }

  static Future<List<Map<String, dynamic>>> _requiredList(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final decoded = await decodeJsonResult(
      await backendChannel.invokeMethod<Object?>(method, args),
    );
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
