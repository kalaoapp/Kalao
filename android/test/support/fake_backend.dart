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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  Map<String, Object?> _args(MethodCall call) =>
      (call.arguments as Map?)?.cast<String, Object?>() ?? const {};

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final args = _args(call);
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
        final path = args['path'] as String;
        final extension = path.split('.').last.toLowerCase();
        return jsonEncode({
          'codec': extension,
          'sampleRate': 44100,
          'channels': 2,
          'durationMs': 180000,
          'title': null,
          'artist': null,
          'decodable': !undecodable.contains(extension),
        });
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
        return jsonEncode(
          _annotate(
            (args['lines'] as List).cast<String>(),
            (args['layers'] as List?)?.cast<String>() ?? const ['pinyin'],
          ),
        );
      case 'convertChinese':
        return jsonEncode([
          for (final text in (args['texts'] as List).cast<String>())
            args['to'] == 't2s'
                ? text.replaceAll('愛', '爱')
                : text.replaceAll('爱', '愛'),
        ]);
      case 'setScreenAwake':
        return null;
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

  static Map<String, Object?> _job(Map<String, Object?> request) {
    switch (request['operation']) {
      case 'hash_file':
        // FNV-1a over the content: equal files hash equally, as SHA-256 does.
        var hash = 0x811c9dc5;
        for (final byte in File(request['path'] as String).readAsBytesSync()) {
          hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
        }
        return {'sha256': hash.toRadixString(16).padLeft(64, '0')};
      case 'rebuildSearchKeys':
        String norm(String value) => value.toLowerCase().replaceAll(
          RegExp(r'[^\p{L}\p{N}]', unicode: true),
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
      default:
        throw PlatformException(
          code: 'ERROR',
          message: 'Unknown native data job',
        );
    }
  }
}
