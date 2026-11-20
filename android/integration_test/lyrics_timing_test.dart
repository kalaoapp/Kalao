// Timing accuracy on a device (IMPLEMENTATION.md §4, §17): a click
// track plays on the real engine while Dart follows an LRC whose lines sit on
// the clicks. The interpolated position that drives lyrics must stay within
// ±30 ms of the engine clock, and every line must turn active within ±30 ms
// of its time.
//
// Run with a device or emulator attached:
//   fvm flutter test integration_test/lyrics_timing_test.dart
//
// What the engine clock means in sound (rendered audio against the reported
// position, through the resampler and at a slowed tempo) is covered by
// `reported_position_tracks_rendered_clicks_within_30_ms` in kalao-audio.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:path_provider/path_provider.dart';

const _toleranceMs = 30;
const _sampleRate = 44100;
const _seconds = 8;

/// 16-bit stereo WAV with a 5 ms click at every whole second.
Uint8List _clickTrack() {
  const frames = _sampleRate * _seconds;
  final data = ByteData(44 + frames * 4);
  void tag(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, _sampleRate, Endian.little);
  data.setUint32(28, _sampleRate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  const clickFrames = _sampleRate * 5 ~/ 1000;
  for (var frame = 0; frame < frames; frame++) {
    final click = frame >= _sampleRate && frame % _sampleRate < clickFrames;
    final sample = click ? 20000 : 0;
    data.setInt16(44 + frame * 4, sample, Endian.little);
    data.setInt16(46 + frame * 4, sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('timed lyrics follow the engine clock within ±30 ms', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await getTemporaryDirectory();
      final wav = File('${directory.path}/kalao-click-track.wav');
      await wav.writeAsBytes(_clickTrack());
      final lrc = [
        for (var second = 1; second < _seconds - 1; second++)
          '[00:0$second.00]click $second',
      ].join('\n');
      final doc = LyricDocument.fromJson(
        await PlatformBridge.parseLyrics(lrc, format: 'lrc'),
      );
      expect(doc.timed, isTrue);

      final deck = KaraokeDeck()..start();
      addTearDown(() async {
        await PlatformBridge.playerStop();
        await deck.dispose();
        if (wav.existsSync()) await wav.delete();
      });
      await deck.load(songId: 'click-track', sources: {'original': wav.path});
      await deck.play();

      final turnedActiveAt = <int, int>{};
      var worstDrift = 0;
      int? active;
      final lastLine = doc.lines.last.time.inMilliseconds;
      final giveUp = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(giveUp)) {
        // The engine clock, bracketed by two reads of what Dart would draw.
        final before = deck.position.inMilliseconds;
        final engine = await PlatformBridge.playerState();
        final after = deck.position.inMilliseconds;
        if (engine.playing && !engine.buffering) {
          final drift = engine.positionMs < before
              ? before - engine.positionMs
              : engine.positionMs > after
              ? engine.positionMs - after
              : 0;
          if (drift > worstDrift) worstDrift = drift;
        }
        final current = doc.activeLineAt(deck.position);
        if (current != null && current != active) {
          active = current;
          turnedActiveAt[current] = engine.positionMs;
        }
        if (engine.positionMs > lastLine + 500 || engine.completed) break;
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }

      expect(turnedActiveAt, hasLength(doc.lines.length));
      expect(
        worstDrift,
        lessThanOrEqualTo(_toleranceMs),
        reason: 'interpolated position against the engine clock',
      );
      for (final MapEntry(key: index, value: at) in turnedActiveAt.entries) {
        final error = at - doc.lines[index].time.inMilliseconds;
        expect(
          error.abs(),
          lessThanOrEqualTo(_toleranceMs),
          reason: 'line $index turned active at $at ms',
        );
      }
    });
  });
}
