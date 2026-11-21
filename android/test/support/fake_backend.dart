import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/services/backend/method_channel_backend.dart';

/// Answers the backend channel the way the Android host does: Rust methods
/// reply with JSON text, Android-native methods with typed values. Player,
/// import and lyrics methods are small stand-ins for the Rust ones (which
/// have their own tests in `rust_backend`).
class FakeBackend {
  final calls = <MethodCall>[];
  String? crashReport;

  /// SAF stand-ins: documents by URI (their copied file) and the URI the
  /// next `createDocument` returns (null = the user cancelled).
  final documents = <String, File>{};
  String? nextDocumentUri = 'content://docs/picked';
  String? nextTreeUri = 'content://tree/primary%3ABackups';
  Directory? documentRoot;

  /// Files the host hands to `takeSharedFiles` once.
  final shared = <Map<String, String>>[];

  // Extensions: a small stand-in for kalao-extensions (it has its own tests).

  /// Installed extensions as `listExtensions` reports them (see
  /// [extensionInfo]).
  final extensions = <Map<String, Object?>>[];
  final priority = <String, List<String>>{};

  /// `inspectExtensionPackage` / `installExtension` by package path.
  final packages = <String, Map<String, Object?>>{};
  final lyricsCandidates = <Map<String, Object?>>[];
  final tracks = <Map<String, Object?>>[];
  final audioSources = <Map<String, Object?>>[];
  final repositoryListings = <Map<String, Object?>>[];
  final secretUpdates = <String, Map<String, Object?>>{};
  final authRequests = <Map<String, Object?>>[];

  /// Login redirects the host hands to `takeExtensionCallbacks` once.
  final extensionCallbacks = <String>[];
  Object? actionResult = 'done';

  /// Secrets Rust holds in memory, by extension id.
  final heldSecrets = <String, Map<String, Object?>>{};

  /// An installed-extension record for [extensions] and [packages].
  static Map<String, Object?> extensionInfo(
    String id, {
    String name = 'Test extension',
    String version = '1.0.0',
    List<String> capabilities = const ['lyrics'],
    List<Map<String, Object?>> settings = const [],
    bool enabled = true,
    List<String> hosts = const ['api.example.org'],
  }) => {
    'id': id,
    'manifest': {
      'schema': 1,
      'id': id,
      'name': name,
      'version': version,
      'author': 'Tests',
      'capabilities': capabilities,
      'network': {'hosts': hosts},
      'settings': settings,
    },
    'enabled': enabled,
    'version': version,
    'source': {'kind': 'file'},
    'sha256': 'ab' * 32,
    'packagePath': '/fake/$id/package.kalaoext',
    'settings': <String, Object?>{},
    'secretsSet': <String>[],
    'missingSecrets': [
      for (final setting in settings)
        if (setting['type'] == 'secret') setting['key'],
    ],
    'degraded': false,
    'supported': true,
    'storageBytes': 0,
  };

  /// Installs [info] as Rust would: listed, and last in the order of each
  /// of its capabilities.
  void addExtension(Map<String, Object?> info) {
    extensions
      ..removeWhere((other) => other['id'] == info['id'])
      ..add(info);
    final manifest = info['manifest']! as Map;
    for (final capability in manifest['capabilities'] as List) {
      final order = priority.putIfAbsent('$capability', () => []);
      if (!order.contains(info['id'])) order.add(info['id']! as String);
    }
  }

  Map<String, Object?>? _extension(Object? id) {
    for (final info in extensions) {
      if (info['id'] == id) return info;
    }
    return null;
  }

  Object? _extensions(String method, Map<String, Object?> args) {
    switch (method) {
      case 'extensionsInit':
        return {'extensions': extensions};
      case 'listExtensions':
        return {
          'extensions': extensions,
          'priority': priority,
          'developerMode': false,
        };
      case 'inspectExtensionPackage':
        final info = packages[args['path']];
        if (info == null) throw 'not a valid .kalaoext package';
        final installed = _extension(info['id']);
        return {
          'manifest': info['manifest'],
          'sha256': info['sha256'],
          'bytes': 1234,
          'installedVersion': installed?['version'],
          'isUpdate': installed != null,
          'isDowngrade': false,
          'isReinstall': false,
          'supported': true,
          'verifiedBy': null,
        };
      case 'installExtension':
        final info = packages[args['path']];
        if (info == null) throw 'not a valid .kalaoext package';
        addExtension(info);
        return info;
      case 'installExtensionFolder':
        throw 'installing from a folder needs developer mode';
      case 'uninstallExtension':
        final info = _extension(args['id']);
        if (info == null) throw 'extension is not installed';
        extensions.remove(info);
        for (final order in priority.values) {
          order.remove(args['id']);
        }
        return null;
      case 'setExtensionEnabled':
        _extension(args['id'])?['enabled'] = args['enabled'];
        return null;
      case 'setExtensionPriority':
        priority[args['capability']! as String] = [
          for (final id in args['ids']! as List) '$id',
        ];
        return priority;
      case 'setExtensionSetting':
        final info = _extension(args['id']);
        if (info == null) throw 'extension is not installed';
        final settings = ((info['manifest']! as Map)['settings'] as List)
            .cast<Map<dynamic, dynamic>>();
        final secret = settings.any(
          (s) => s['key'] == args['key'] && s['type'] == 'secret',
        );
        if (secret) {
          final held = heldSecrets.putIfAbsent(info['id']! as String, () => {});
          if (args['value'] case final String value when value.isNotEmpty) {
            held[args['key']! as String] = value;
          } else {
            held.remove(args['key']);
          }
          info['secretsSet'] = held.keys.toList();
          info['missingSecrets'] = [
            for (final s in settings)
              if (s['type'] == 'secret' && !held.containsKey(s['key']))
                s['key'],
          ];
        } else {
          (info['settings']! as Map)[args['key']] = args['value'];
        }
        return null;
      case 'setExtensionSecrets':
        final values = (args['values']! as Map).cast<String, Object?>();
        heldSecrets[args['id']! as String] = values;
        final info = _extension(args['id']);
        if (info != null) {
          info['secretsSet'] = values.keys.toList();
          info['missingSecrets'] = [
            for (final key in info['missingSecrets']! as List)
              if (!values.containsKey(key)) key,
          ];
        }
        return null;
      case 'takeExtensionSecretUpdates':
        final taken = {...secretUpdates};
        secretUpdates.clear();
        return taken;
      case 'setExtensionDeveloperMode':
      case 'extensionAuthCallback':
      case 'removeRepository':
        return null;
      case 'addRepository':
        repositoryListings.add({
          'repository': {
            'url': args['url'],
            'name': args['name'] ?? 'Repo',
            'publicKey': args['publicKey'],
          },
          'entries': <Object?>[],
        });
        return null;
      case 'invokeExtensionAction':
        return {'result': actionResult};
      case 'takeExtensionAuthRequest':
        return authRequests.isEmpty ? null : authRequests.removeAt(0);
      case 'extensionHealth':
        return {'ok': true, 'checks': <Object?>[]};
      case 'extensionLogs':
        return {'logs': <Object?>[]};
      case 'listRepositories':
        return [
          for (final listing in repositoryListings) listing['repository'],
        ];
      case 'previewRepository':
        return {
          'url': args['url'],
          'name': 'Repo',
          'publicKey': 'ed25519:key',
          'fingerprint': 'aaaa:bbbb',
          'extensions': 1,
        };
      case 'refreshRepositories':
        return {'repositories': repositoryListings};
      case 'installFromRepository':
        final info = extensionInfo(args['id']! as String);
        addExtension(info);
        return info;
      case 'searchLyrics':
        return {'candidates': lyricsCandidates, 'errors': <Object?>[]};
      case 'getLyrics':
        return lyricsCandidates.firstWhere(
          (c) =>
              c['id'] == args['id'] && c['extensionId'] == args['extensionId'],
        );
      case 'searchMetadata':
        return {'tracks': tracks, 'errors': <Object?>[]};
      case 'getTrack':
        return tracks.firstWhere((t) => t['id'] == args['id']);
      case 'getArtwork':
        return {'extensionId': null, 'images': <Object?>[]};
      case 'resolveAudio':
        if (audioSources.isEmpty) throw 'no audio sources';
        return {'extensionId': args['extensionId'], 'sources': audioSources};
    }
    return _notConnected;
  }

  static const _notConnected = Object();

  /// Methods that fail with a PlatformException carrying their message.
  final failing = <String, String>{};

  /// File names whose probe reports `decodable: false`.
  final undecodable = <String>{'opus', 'wma', 'ape'};

  Map<String, Object?> player = _idle();

  static Map<String, Object?> _idle() => {
    'songId': null,
    'sources': null,
    'layout': null,
    'durationMs': null,
    'positionMs': 0,
    'playing': false,
    'completed': false,
    'buffering': false,
    'vocalLevel': 1.0,
    'volume': 1.0,
    'tempo': 1.0,
    'key': 0.0,
    'loopStartMs': null,
    'loopEndMs': null,
  };

  /// Readings for the few characters tests use.
  static const pinyin = {'你': 'nǐ', '好': 'hǎo', '月': 'yuè', '亮': 'liang'};

  static const _channel = MethodChannel(MethodChannelBackend.channelName);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  void uninstall() {
    if (documentRoot?.existsSync() ?? false) {
      documentRoot!.deleteSync(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  /// The arguments of [call]: JSON text for Rust methods (as `PlatformBridge`
  /// sends them), a map for Android-native ones.
  static Map<String, Object?> argsOf(MethodCall call) =>
      switch (call.arguments) {
        final String json => (jsonDecode(json) as Map).cast<String, Object?>(),
        final Map<Object?, Object?> map => map.cast<String, Object?>(),
        _ => const {},
      };

  Map<String, Object?> _args(MethodCall call) => argsOf(call);

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    if (failing[call.method] case final message?) {
      throw PlatformException(code: 'ERROR', message: message);
    }
    final args = _args(call);
    final extension = _extensionsOrFail(call.method, args);
    if (!identical(extension, _notConnected)) return extension;
    switch (call.method) {
      case 'getBackendInfo':
        return jsonEncode({
          'name': 'kalao-mobile',
          'version': '0.1.0',
          'os': 'android',
          'arch': 'aarch64',
          'initialized': true,
          'methods': ['getBackendInfo'],
        });
      case 'getLogs':
        return jsonEncode({
          'logs': [
            {
              'timestamp': '12:00:00.000',
              'level': 'INFO',
              'tag': 'Backend',
              'message': 'initialized',
            },
          ],
          'next_index': 1,
        });
      case 'setLoggingEnabled':
      case 'clearLogs':
        return 'null';
      case 'readLastCrashReport':
        return crashReport;
      case 'clearLastCrashReport':
      case 'recordAppRuntimeError':
      case 'stopBackgroundWork':
      case 'updateBackgroundWork':
        return null;
      case 'startBackgroundWork':
        return true;
      case 'playerLoad':
        final sources = [
          for (final source in args['sources'] as List)
            (source as Map)['kind'] as String,
        ];
        player = {
          ..._idle(),
          'songId': args['songId'],
          'sources': sources,
          'layout': sources.contains('instrumental') && sources.length > 1
              ? 'pair'
              : 'single',
          'durationMs': 180000,
          'positionMs': args['startMs'] ?? 0,
          'vocalLevel': player['vocalLevel'],
          'tempo': player['tempo'],
          'key': player['key'],
        };
        return jsonEncode(player);
      case 'playerPlay':
        player['playing'] = true;
        return jsonEncode(player);
      case 'playerPause':
        player['playing'] = false;
        return jsonEncode(player);
      case 'playerStop':
        player = _idle();
        return jsonEncode(player);
      case 'playerSeek':
        player['positionMs'] = args['ms'];
        return jsonEncode(player);
      case 'playerSwitchTrack':
        player['vocalLevel'] = args['kind'] == 'instrumental' ? 0.0 : 1.0;
        return jsonEncode(player);
      case 'playerSetStemGains':
        if (args['vocals'] != null) player['vocalLevel'] = args['vocals'];
        return jsonEncode(player);
      case 'playerSetVolume':
        player['volume'] = args['volume'];
        return jsonEncode(player);
      case 'playerSetKey':
        player['key'] = args['semitones'];
        return jsonEncode(player);
      case 'playerSetLoop':
        player['loopStartMs'] = args['startMs'];
        player['loopEndMs'] = args['endMs'];
        return jsonEncode(player);
      case 'playerSetTempo':
        player['tempo'] = args['rate'];
        return jsonEncode(player);
      case 'playerState':
        return jsonEncode(player);
      case 'probeAudio':
        return jsonEncode(_probe(args['path'] as String));
      case 'pairImportFiles':
        return jsonEncode(_pair(args['files'] as List));
      case 'parseLyrics':
        return jsonEncode(_parse(args['raw'] as String));
      case 'exportLyrics':
        return jsonEncode({
          'text': _export(
            (args['doc'] as Map).cast<String, Object?>(),
            args['format'] as String,
          ),
        });
      case 'annotateLyrics':
        final lines = (args['lines'] as List).cast<String>();
        final language = lines.any(RegExp('[ぁ-ヿ]').hasMatch)
            ? 'ja'
            : lines.any(RegExp('[一-鿿]').hasMatch)
            ? 'zh'
            : null;
        return jsonEncode({
          'sourceLang': language,
          'layers': _annotate(
            lines,
            (args['layers'] as List?)?.cast<String>() ??
                switch (language) {
                  'ja' => const ['furigana', 'romaji'],
                  'zh' => const ['pinyin'],
                  _ => const <String>[],
                },
          ),
        });
      case 'convertChinese':
        return jsonEncode([
          for (final text in (args['texts'] as List).cast<String>())
            args['to'] == 't2s'
                ? text.replaceAll('愛', '爱')
                : text.replaceAll('爱', '愛'),
        ]);
      case 'setScreenAwake':
        return null;
      case 'getSupportedAbis':
        return ['arm64-v8a', 'armeabi-v7a'];
      case 'installApk':
        return true;
      case 'takeExtensionCallbacks':
        final taken = [...extensionCallbacks];
        extensionCallbacks.clear();
        return taken;
      case 'takeSharedFiles':
        final taken = [...shared];
        shared.clear();
        return taken;
      case 'createDocument':
        return nextDocumentUri;
      case 'pickDocumentTree':
        return nextTreeUri;
      case 'copyFileToDocument':
        _storeDocument(args['uri'] as String, args['path'] as String);
        return null;
      case 'writeFileToTree':
        final uri = '${args['treeUri']}/document/${args['name']}';
        _storeDocument(uri, args['path'] as String);
        return uri;
      case 'listDocumentTree':
        final prefix = '${args['treeUri']}/document/';
        return [
          for (final MapEntry(key: uri, value: file) in documents.entries)
            if (uri.startsWith(prefix))
              {
                'uri': uri,
                'name': uri.substring(prefix.length),
                'bytes': file.lengthSync(),
                'modified': 0,
              },
        ];
      case 'deleteDocument':
        return documents.remove(args['uri'] as String)?.existsSync() ?? false;
      case 'runNativeDataJob':
        final request = jsonDecode(args['request_json'] as String) as Map;
        return jsonEncode(_job(request.cast<String, Object?>()));
      default:
        throw PlatformException(
          code: 'ERROR',
          message:
              'Rust application method is not connected yet: ${call.method}',
        );
    }
  }

  /// Extension methods reply with JSON text; a thrown string becomes the
  /// PlatformException Rust's error would.
  Object? _extensionsOrFail(String method, Map<String, Object?> args) {
    try {
      final reply = _extensions(method, args);
      return identical(reply, _notConnected) ? reply : jsonEncode(reply);
    } on String catch (message) {
      throw PlatformException(code: 'ERROR', message: message);
    }
  }

  Map<String, Object?> _probe(String path) {
    final extension = path.split('.').last.toLowerCase();
    return {
      'codec': extension,
      'sampleRate': 44100,
      'channels': 2,
      'durationMs': 180000,
      'title': null,
      'artist': null,
      'decodable': !undecodable.contains(extension),
    };
  }

  void _storeDocument(String uri, String path) {
    final root = documentRoot ??= Directory.systemTemp.createTempSync(
      'kalao-docs-',
    );
    final copy = File('${root.path}/${documents.length}-${uri.hashCode}');
    File(path).copySync(copy.path);
    documents[uri] = copy;
  }

  static bool _isInstrumental(String name) =>
      RegExp(r'instrumental|karaoke|伴奏', caseSensitive: false).hasMatch(name);

  static String _base(String name) => name
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .replaceAll(
        RegExp(r'\(?(instrumental|karaoke|伴奏)\)?', caseSensitive: false),
        '',
      )
      .trim()
      .toLowerCase();

  List<Map<String, Object?>> _pair(List<dynamic> files) {
    final names = [for (final file in files) (file as Map)['name'] as String];
    bool audio(String name) => !name.endsWith('.lrc') && !name.endsWith('.txt');
    final proposals = <Map<String, Object?>>[];
    for (var i = 0; i < names.length; i++) {
      if (!audio(names[i]) || _isInstrumental(names[i])) continue;
      int? find(bool Function(String) test) {
        for (var j = 0; j < names.length; j++) {
          if (j != i && test(names[j]) && _base(names[j]) == _base(names[i])) {
            return j;
          }
        }
        return null;
      }

      proposals.add({
        'original': i,
        'instrumental': find((name) => audio(name) && _isInstrumental(name)),
        'lyrics': find((name) => !audio(name)),
        'title': names[i].replaceAll(RegExp(r'\.[^.]+$'), ''),
      });
    }
    return proposals;
  }

  static Map<String, Object?> _parse(String raw) {
    final timed = RegExp(r'^\[(\d+):(\d+)\.(\d+)\](.*)$');
    final lines = <Map<String, Object?>>[];
    var isTimed = false;
    String? section;
    var pendingBreak = false;
    for (final row in raw.split('\n')) {
      final text = row.trim();
      if (text.isEmpty) {
        pendingBreak = lines.isNotEmpty;
        continue;
      }
      final match = timed.firstMatch(text);
      if (match != null) {
        isTimed = true;
        final ms =
            int.parse(match[1]!) * 60000 +
            int.parse(match[2]!) * 1000 +
            int.parse(match[3]!) * 10;
        // Word tags `<mm:ss.xx>word`: each tag starts the word after it.
        final tag = RegExp(r'<(\d+):(\d+)\.(\d+)>');
        final body = match[4]!.trim();
        final words = <Map<String, Object?>>[];
        final tags = tag.allMatches(body).toList();
        for (var i = 0; i < tags.length; i++) {
          final end = i + 1 < tags.length ? tags[i + 1].start : body.length;
          final word = body.substring(tags[i].end, end).trim();
          if (word.isEmpty) continue;
          words.add({
            'timeMs':
                int.parse(tags[i][1]!) * 60000 +
                int.parse(tags[i][2]!) * 1000 +
                int.parse(tags[i][3]!) * 10,
            'text': word,
          });
        }
        lines.add({
          'timeMs': ms,
          'text': body.replaceAll(tag, '').trim(),
          if (words.isNotEmpty) 'words': words,
          'sectionBreakBefore': false,
        });
        continue;
      }
      if (RegExp(r'^\[(Verse|Chorus)[^\]]*\]$').hasMatch(text)) {
        section = text.contains('Chorus') ? 'chorus' : 'verse';
        pendingBreak = lines.isNotEmpty;
        continue;
      }
      lines.add({
        'timeMs': 0,
        'text': text,
        'section': ?section,
        'sectionBreakBefore': pendingBreak,
      });
      section = null;
      pendingBreak = false;
    }
    return {
      'version': 2,
      'format': isTimed ? 'lrc' : 'plain',
      'timed': isTimed,
      'offsetMs': 0,
      'lines': lines,
    };
  }

  static String _stamp(Object? ms) {
    final value = (ms as num).toInt();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value ~/ 60000)}:${two(value ~/ 1000 % 60)}.${two(value % 1000 ~/ 10)}';
  }

  /// `[mm:ss.xx]text` rows; `elrc` adds a `<mm:ss.xx>` tag before each word.
  static String _export(Map<String, Object?> doc, String format) {
    final rows = <String>[
      if (doc['title'] != null) '[ti:${doc['title']}]',
      if (doc['artist'] != null) '[ar:${doc['artist']}]',
    ];
    for (final item in doc['lines'] as List) {
      final line = (item as Map).cast<String, Object?>();
      final words = line['words'] as List?;
      final body = format == 'elrc' && words != null
          ? [
              for (final word in words)
                '<${_stamp((word as Map)['timeMs'])}>${word['text']}',
            ].join(' ')
          : line['text'];
      rows.add('[${_stamp(line['timeMs'])}]$body');
    }
    return '${rows.join('\n')}\n';
  }

  /// Kana readings and romaji for the few kanji tests use.
  static const furigana = {'桜': 'さくら', '咲': 'さ'};
  static const romaji = {'桜': 'sakura', '咲': 'sa', 'く': 'ku', 'が': 'ga'};

  static List<Map<String, Object?>> _annotate(
    List<String> lines,
    List<String> layers,
  ) => [
    for (final layer in layers)
      for (var i = 0; i < lines.length; i++)
        if (lines[i].split('').any(_readings(layer).containsKey))
          {
            'lineIndex': i,
            'kind': layer,
            'origin': 'auto',
            'segments': [
              for (var c = 0; c < lines[i].length; c++)
                if (_readings(layer)[lines[i][c]] case final reading?)
                  {'start': c, 'end': c + 1, 'reading': reading},
            ],
          },
  ];

  static Map<String, String> _readings(String layer) => switch (layer) {
    'furigana' => furigana,
    'romaji' => romaji,
    _ => pinyin,
  };

  /// FNV-1a over the content: equal files hash equally, as SHA-256 does.
  static String _fnv(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(64, '0');
  }

  /// Requests of the `importInspect` / `importStore` jobs, for assertions.
  final importJobs = <Map<String, Object?>>[];

  Map<String, Object?> _job(Map<String, Object?> request) {
    switch (request['operation']) {
      case 'hash_file':
        return {
          'sha256': _fnv(File(request['path'] as String).readAsBytesSync()),
        };
      case 'importInspect':
        importJobs.add(request);
        final path = request['path'] as String;
        return {
          'sha256': _fnv(File(path).readAsBytesSync()),
          'probe': _probe(path),
        };
      case 'importStore':
        importJobs.add(request);
        final source = File(request['path'] as String);
        final extension = source.path.split('.').last.toLowerCase();
        final target = File(
          '${request['mediaDir']}${Platform.pathSeparator}'
          '${request['sha256']}.$extension',
        );
        Directory(request['mediaDir'] as String).createSync(recursive: true);
        if (target.existsSync()) {
          source.deleteSync();
        } else {
          source.renameSync(target.path);
        }
        return {
          'path': target.path,
          'bytes': target.lengthSync(),
          'probe': _probe(target.path),
        };
      case 'rebuildSearchKeys':
        String norm(String value) => value.toLowerCase().replaceAll(
          RegExp(r'[^\p{Alphabetic}\p{N}]', unicode: true),
          '',
        );
        return {
          'rows': [
            for (final song in request['songs'] as List)
              ...() {
                final map = (song as Map).cast<String, Object?>();
                final title = map['title'] as String? ?? '';
                return [
                  {'songId': map['id'], 'keyKind': 'title', 'key': norm(title)},
                  {
                    'songId': map['id'],
                    'keyKind': 'artist',
                    'key': norm(map['artist'] as String? ?? ''),
                  },
                  if (title.contains('月亮'))
                    {
                      'songId': map['id'],
                      'keyKind': 'pinyin',
                      'key': 'yueliang',
                    },
                ];
              }(),
          ],
        };
      case 'extensionDownload':
        // The "download": a small file named after the URL.
        final target = File(request['path']! as String)
          ..createSync(recursive: true)
          ..writeAsStringSync('audio from ${request['url']}');
        return {'path': target.path, 'bytes': target.lengthSync()};
      case 'backupWrite':
        // A JSON stand-in for the ZIP: same manifest, same entry checks.
        final files = <String, String>{};
        final sums = <String, Object?>{};
        for (final entry in request['entries'] as List) {
          final map = (entry as Map).cast<String, Object?>();
          final bytes = File(map['path'] as String).readAsBytesSync();
          files[map['name'] as String] = base64Encode(bytes);
          sums[map['name'] as String] = {
            'sha256': _fnv(bytes),
            'bytes': bytes.length,
          };
        }
        final manifest = {
          ...(request['manifest'] as Map).cast<String, Object?>(),
          'entries': sums,
        };
        final output = File(request['output'] as String)
          ..writeAsStringSync(
            jsonEncode({'manifest': manifest, 'files': files}),
          );
        return {'bytes': output.lengthSync(), 'entries': files.length};
      case 'backupInspect':
        final Map<String, Object?> archive;
        try {
          archive =
              (jsonDecode(File(request['path'] as String).readAsStringSync())
                      as Map)
                  .cast<String, Object?>();
        } on FormatException {
          throw PlatformException(
            code: 'ERROR',
            message: 'This file is not a Kalao backup',
          );
        }
        final manifest = (archive['manifest'] as Map).cast<String, Object?>();
        if ((manifest['format'] as int) > (request['maxFormat'] as int)) {
          throw PlatformException(
            code: 'ERROR',
            message: 'This backup was made by a newer version of Kalao',
          );
        }
        final target = request['extractTo'] as String;
        for (final MapEntry(:key, :value)
            in (archive['files'] as Map).cast<String, String>().entries) {
          File('$target/$key')
            ..createSync(recursive: true)
            ..writeAsBytesSync(base64Decode(value));
        }
        return manifest;
      default:
        throw PlatformException(
          code: 'ERROR',
          message: 'Unknown native data job',
        );
    }
  }
}
