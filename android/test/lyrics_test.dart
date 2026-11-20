import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/app.dart';
import 'package:kalao/controllers/lyrics_sync_editor_controller.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/screens/lyrics_sync_screen.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/utils/lyrics_timeline.dart';
import 'package:kalao/widgets/ruby_lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

Duration ms(int value) => Duration(milliseconds: value);

LyricLine line(
  String text,
  int time, {
  int? end,
  List<(String, int, int?)> words = const [],
  String? voice,
}) => LyricLine.fromJson({
  'text': text,
  'timeMs': time,
  'endMs': ?end,
  'voice': ?voice,
  'words': [
    for (final (word, start, wordEnd) in words)
      {'text': word, 'timeMs': start, 'endMs': ?wordEnd},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model', () {
    test('words are located in the line text and survive JSON', () {
      final parsed = line(
        'Hello big world',
        1000,
        end: 2500,
        words: [
          ('Hello', 1000, 1400),
          ('big', 1450, 1900),
          ('world', 1900, null),
        ],
      );
      expect([for (final word in parsed.words) word.start], [0, 6, 10]);
      expect(parsed.words.last.end, isNull);
      final again = LyricLine.fromJson(
        (jsonDecode(jsonEncode(parsed.toJson())) as Map).cast(),
      );
      expect(again.words, parsed.words);
      expect(again.end, ms(2500));
      // A word that is not in the text is dropped, not misplaced.
      expect(line('abc', 0, words: [('zzz', 0, 10), ('b', 5, 9)]).words, [
        LyricWord(text: 'b', time: ms(5), end: ms(9), start: 1),
      ]);
    });

    test('the active line follows the offset and skips backing lines', () {
      final doc = LyricDocument(
        timed: true,
        offsetMs: 200,
        lines: [
          line('one', 1000),
          line('two', 3000),
          line('(ooh)', 3200, voice: backingVoice),
          line('three', 5000),
        ],
      );
      expect(doc.activeLineAt(ms(700)), isNull);
      expect(doc.activeLineAt(ms(800)), 0);
      expect(doc.activeLineAt(ms(2799)), 0);
      expect(doc.activeLineAt(ms(2800)), 1);
      expect(doc.activeLineAt(ms(3500)), 1);
      expect(doc.activeLineAt(ms(4800)), 3);
      expect(doc.copyWith(timed: false).activeLineAt(ms(4800)), isNull);
      expect(doc.toJson()['version'], 2);
      expect(doc.hasWordTiming, isFalse);
    });
  });

  group('timeline', () {
    test('word sweep crosses each word during that word', () {
      final sung = line(
        'Hello big world',
        1000,
        end: 3000,
        words: [
          ('Hello', 1000, 1400),
          ('big', 1600, 1900),
          ('world', 1900, null),
        ],
      );
      expect(sweptChars(sung, 900), 0);
      expect(sweptChars(sung, 1200), closeTo(2.5, 1e-9));
      // Between words the sweep rests on the space before the next word.
      expect(sweptChars(sung, 1500), 6);
      expect(sweptChars(sung, 1750), closeTo(7.5, 1e-9));
      // The last word has no end: it runs to the line end.
      expect(sweptChars(sung, 2450), closeTo(12.5, 1e-9));
      expect(sweptChars(sung, 9000), 15);
    });

    test('lines without word timing sweep linearly, capped', () {
      final plain = line('abcdefghij', 2000);
      expect(sweptChars(plain, 3000, nextStartMs: 4000), closeTo(5, 1e-9));
      expect(sweptChars(plain, 4000, nextStartMs: 4000), 10);
      // Own end wins over the next line; no end and no next line: 5 s.
      expect(sweptChars(line('abcd', 0, end: 1000), 500, nextStartMs: 9000), 2);
      expect(sweptChars(line('abcd', 0), 2500), 2);
      // A long gap before the next line does not make the sweep crawl.
      expect(
        sweptChars(plain, 2000 + maxLinearSweepMs, nextStartMs: 60000),
        10,
      );
      expect(
        nextLeadStartMs([
          plain,
          line('x', 2500, voice: backingVoice),
          line('y', 4000),
        ], 0),
        4000,
      );
    });

    test('splitWords: CJK per character, other scripts per word', () {
      List<String> split(String text) => [
        for (final (start, end) in splitWords(text)) text.substring(start, end),
      ];
      expect(split('月亮代表我的心'), ['月', '亮', '代', '表', '我', '的', '心']);
      expect(split("Don't stop,  believin'!"), [
        "Don't",
        'stop,',
        "believin'!",
      ]);
      expect(split('你好，world！ (yeah) ♪'), ['你', '好，', 'world！', '(yeah) ♪']);
      expect(split('「さくら」 咲く'), ['「さ', 'く', 'ら」', '咲', 'く']);
      expect(split('   '), isEmpty);
      expect(split('…'), ['…']);
    });
  });

  group('sync editor', () {
    LyricDocument untimed() => LyricDocument(
      lines: [
        LyricLine(
          text: '你好',
          section: 'verse',
          layers: {
            LyricLayerKind.pinyin: const LyricLayer(
              segments: [RubySegment(0, 1, 'nǐ'), RubySegment(1, 2, 'hǎo')],
            ),
          },
        ),
        const LyricLine(text: 'second line'),
        const LyricLine(text: 'third'),
      ],
    );

    test('line mode: taps stamp starts, a hold stamps the end', () {
      final editor = LyricsSyncEditor(untimed());
      expect(editor.remaining, 3);
      expect(editor.complete, isFalse);
      editor
        ..tapDown(1000)
        ..tapUp(1100, held: ms(100));
      expect(editor.cursor, 1);
      expect(editor.lines[0].timeMs, 1000);
      expect(editor.lines[0].endMs, isNull);
      editor
        ..tapDown(3000)
        ..tapUp(4200, held: ms(1200))
        ..tapDown(6000)
        ..tapUp(6050, held: ms(50));
      expect(editor.lines[1].endMs, 4200);
      expect(editor.finished, isTrue);
      expect(editor.complete, isTrue);
      // More taps after the last line change nothing.
      editor.tapDown(9000);
      expect(editor.lines[2].timeMs, 6000);

      final doc = editor.build();
      expect(doc.timed, isTrue);
      expect(doc.format, 'lrc');
      expect(
        [for (final l in doc.lines) l.time],
        [ms(1000), ms(3000), ms(6000)],
      );
      expect(doc.lines[1].end, ms(4200));
      // Text, sections and layers come through untouched.
      expect(doc.lines[0].section, 'verse');
      expect(
        doc.lines[0].layers[LyricLayerKind.pinyin]!.segments,
        hasLength(2),
      );
    });

    test('word mode stamps each word and moves to the next line', () {
      final editor = LyricsSyncEditor(untimed())..setMode(SyncMode.word);
      editor
        ..tapDown(1000)
        ..tapUp(1050, held: ms(50));
      expect(editor.cursor, 0);
      expect(editor.wordCursor, 1);
      editor
        ..tapDown(1500)
        ..tapUp(2100, held: ms(600));
      expect(editor.cursor, 1);
      expect(editor.lines[0].timeMs, 1000);
      expect(editor.lines[0].endMs, 2100);
      expect(editor.lines[0].wordTimed, isTrue);
      editor
        ..tapDown(3000)
        ..tapUp(3010, held: ms(10))
        ..tapDown(3500)
        ..tapUp(3510, held: ms(10))
        ..setMode(SyncMode.line)
        ..tapDown(5000)
        ..tapUp(5010, held: ms(10));
      final doc = editor.build();
      expect(doc.format, 'elrc');
      expect(doc.lines[0].words, [
        LyricWord(text: '你', time: ms(1000)),
        LyricWord(text: '好', time: ms(1500), end: ms(2100), start: 1),
      ]);
      expect([for (final w in doc.lines[1].words) w.text], ['second', 'line']);
      expect(doc.lines[2].words, isEmpty);
    });

    test('nudge moves the last stamp, undo restores, select re-times', () {
      final editor = LyricsSyncEditor(untimed());
      expect(editor.canUndo, isFalse);
      editor.nudge(50);
      expect(editor.canUndo, isFalse);
      editor
        ..tapDown(1000)
        ..tapUp(2000, held: ms(1000))
        ..nudge(-50)
        ..nudge(10);
      expect(editor.lines[0].timeMs, 960);
      expect(editor.lines[0].endMs, 1960);
      editor.undo();
      expect(editor.lines[0].timeMs, 950);
      editor
        ..undo()
        ..undo();
      expect(editor.lines[0].timeMs, isNull);
      expect(editor.cursor, 0);
      expect(editor.canUndo, isFalse);

      // In word mode a nudge moves one word (and the line start with the
      // first word).
      editor
        ..setMode(SyncMode.word)
        ..tapDown(1000)
        ..tapUp(1010, held: ms(10))
        ..nudge(-10);
      expect(editor.lines[0].timeMs, 990);
      expect(editor.lines[0].words[0].timeMs, 990);
      editor
        ..tapDown(1500)
        ..tapUp(1510, held: ms(10))
        ..nudge(50);
      expect(editor.lines[0].timeMs, 990);
      expect(editor.lines[0].words[1].timeMs, 1550);
      // Selecting a line moves the cursor there; a nudge then moves all of it.
      editor
        ..select(0)
        ..nudge(10);
      expect(editor.cursor, 0);
      expect(editor.lines[0].words[1].timeMs, 1560);
      // Tapping the first word again clears the rest of the line.
      editor.tapDown(2000);
      expect(editor.lines[0].words[1].timeMs, isNull);
    });

    test('an existing timed document keeps its timing, offset applied', () {
      final editor = LyricsSyncEditor(
        LyricDocument(
          timed: true,
          offsetMs: 100,
          lines: [
            line(
              'a b',
              1000,
              end: 2000,
              words: [('a', 1000, 1500), ('b', 1500, 2000)],
            ),
            line('c', 3000),
          ],
        ),
      );
      expect(editor.complete, isTrue);
      expect(editor.lines[0].timeMs, 900);
      expect(editor.lines[0].words[1].endMs, 1900);
      // Re-time the second line earlier than the first: lines stay in order.
      editor
        ..select(1)
        ..tapDown(500)
        ..tapUp(510, held: ms(10));
      final doc = editor.build();
      expect(doc.offsetMs, 0);
      expect(doc.lines[1].time, ms(900));
      expect(doc.lines[0].words, hasLength(2));
    });
  });

  group('timing accuracy', () {
    // The engine reports its position at 30 Hz with jitter; the deck
    // interpolates between reports. Model the engine with a simulated clock
    // and check when the active line changes against the true song time.
    for (final tempo in [1.0, 0.5]) {
      test('lines follow within ±30 ms at tempo $tempo', () async {
        var now = Duration.zero;
        final events = StreamController<Object?>(sync: true);
        final deck = KaraokeDeck(events: events.stream, now: () => now)
          ..start();
        final doc = LyricDocument(
          timed: true,
          lines: [for (var i = 1; i <= 8; i++) line('line $i', i * 730)],
        );
        double songMs() => now.inMicroseconds / 1000 * tempo;
        final flips = <int, double>{};
        int? active;
        var nextReport = 0;
        // 7 s of wall time in 1 ms steps; a 60 fps frame reads the deck.
        for (var step = 0; step <= 7000 / tempo; step++) {
          now = Duration(milliseconds: step);
          if (step >= nextReport) {
            // Reports arrive every 33 ms ± 6 ms and are up to 4 ms stale.
            final stale = step % 5;
            events.add(
              jsonEncode({
                'positionMs': (songMs() - stale * tempo).floor(),
                'playing': true,
                'tempo': tempo,
                'durationMs': 60000,
              }),
            );
            now = Duration(milliseconds: step + stale);
            nextReport = step + 27 + (step * 7) % 13;
            now = Duration(milliseconds: step);
          }
          if (step % 16 != 0) continue;
          final current = doc.activeLineAt(deck.position);
          if (current != active && current != null) {
            flips[current] = songMs();
            active = current;
          }
        }
        expect(flips, hasLength(doc.lines.length));
        for (final MapEntry(key: index, value: at) in flips.entries) {
          final error = at - doc.lines[index].time.inMilliseconds;
          // Never early by more than the tolerance; late by at most one
          // frame of song time plus the tolerance.
          expect(error.abs(), lessThanOrEqualTo(30), reason: 'line $index');
        }
        await deck.dispose();
        await events.close();
      });
    }
  });

  group('library and screens', () {
    late FakeBackend backend;
    late LibraryServices services;

    setUp(() async {
      backend = FakeBackend()..install();
      services = await openTestServices();
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode({
          'setupCompleted': true,
          'tutorialSeen': true,
          'whatsNewVersion': '0.1.0',
        }),
      });
    });
    tearDown(() async {
      backend.uninstall();
      await closeTestServices(services);
    });

    Future<Song> addSong() async {
      final id = await services.library.insertSong(
        const NewSong(
          title: 'Moon',
          artist: 'Teresa',
          durationMs: 180000,
          media: [
            NewMediaFile(
              kind: MediaKind.original,
              path: '/m/o.flac',
              sha256: 'o',
            ),
          ],
        ),
      );
      return (await services.library.song(id))!;
    }

    LyricDocument timedDoc() => LyricDocument(
      timed: true,
      format: 'elrc',
      lines: [
        line('first line', 1000, end: 3000),
        line(
          'second words',
          4000,
          end: 6000,
          words: [('second', 4000, 5000), ('words', 5000, 6000)],
        ),
        line('third', 8000),
      ],
    );

    test(
      'import keeps word timing; offset edits the version in place',
      () async {
        final song = await addSong();
        final doc = await services.lyrics.importText(
          song.id,
          '[00:01.00]<00:01.00>你 <00:01.50>好\n[00:03.00]plain',
        );
        expect(doc.timed, isTrue);
        expect(doc.lines[0].text, '你 好');
        expect([for (final w in doc.lines[0].words) w.start], [0, 2]);
        expect(doc.lines[0].layers[LyricLayerKind.pinyin], isNotNull);
        expect(doc.sourceLang, 'zh');

        expect(await services.lyrics.setOffset(song.id, 250), 250);
        expect(await services.lyrics.setOffset(song.id, 99999), 5000);
        final stored = (await services.library.lyrics(song.id))!;
        expect(stored.offsetMs, 5000);
        expect(stored.lines[0].words, hasLength(2));
        expect(stored.lines[0].layers[LyricLayerKind.pinyin], isNotNull);
        final versions = await services.library.db.query('lyric_doc');
        expect(versions, hasLength(1));

        // Saving an edit is a new version that keeps the layers.
        await services.lyrics.save(
          song.id,
          stored.copyWith(offsetMs: 0),
          source: 'userEdited',
        );
        final rows = await services.library.db.query(
          'lyric_doc',
          orderBy: 'version',
        );
        expect(
          [for (final row in rows) row['source_kind']],
          ['paste', 'userEdited'],
        );
        final edited = (await services.library.lyrics(song.id))!;
        expect(edited.offsetMs, 0);
        expect(edited.lines[0].layers[LyricLayerKind.pinyin], isNotNull);

        final text = await services.lyrics.exportText(
          edited,
          'elrc',
          title: song.title,
          artist: song.artist,
        );
        expect(
          text,
          startsWith('[ti:Moon]\n[ar:Teresa]\n[00:01.00]<00:01.00>你'),
        );
        final call = backend.calls.lastWhere((c) => c.method == 'exportLyrics');
        final args = (call.arguments as Map).cast<String, Object?>();
        expect(args['format'], 'elrc');
        expect((args['doc']! as Map)['timed'], isTrue);
      },
    );

    Future<ProviderContainer> pumpPlayer(
      WidgetTester tester,
      Song song,
      StreamController<Object?> events,
    ) async {
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            ...testOverrides(services, events: events.stream),
          ],
          child: const KalaoApp(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      await tester.runAsync(
        () => container.read(playerProvider.notifier).playSong(song),
      );
      return container;
    }

    Future<void> report(
      WidgetTester tester,
      StreamController<Object?> events,
      int positionMs,
    ) async {
      // Paused, so the deck position is exactly the reported one.
      events.add(
        jsonEncode({
          'songId': '1',
          'layout': 'single',
          'positionMs': positionMs,
          'playing': false,
          'durationMs': 180000,
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('timed lyrics follow the position with a sweep and an offset', (
      tester,
    ) async {
      final song = (await tester.runAsync(() async {
        final song = await addSong();
        await services.lyrics.save(song.id, timedDoc(), source: 'file');
        return song;
      }))!;
      final events = StreamController<Object?>();
      addTearDown(events.close);
      final container = await pumpPlayer(tester, song, events);
      container.read(routerProvider).push('/player');
      await report(tester, events, 4500);

      // The second line is active and swept half-way through its first word.
      final sweep = tester.widget<SweepText>(find.byType(SweepText));
      expect(sweep.text, 'second words');
      expect(sweep.swept.value, closeTo(3, 1e-9));

      // A linear sweep on a line without word timing.
      await report(tester, events, 2000);
      final linear = tester.widget<SweepText>(find.byType(SweepText));
      expect(linear.text, 'first line');
      expect(linear.swept.value, closeTo(5, 1e-9));

      // +50 ms offset twice: the lyrics run 100 ms earlier.
      await tester.tap(find.byTooltip('Lyrics options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.byTooltip('Show lyrics earlier'));
      await tester.pump();
      expect(find.text('0.00 s'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Show lyrics earlier'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('+0.10 s'), findsOneWidget);
      expect(container.read(playerProvider).lyrics!.offsetMs, 100);
      final stored = await tester.runAsync(
        () => services.library.lyrics(song.id),
      );
      expect(stored!.offsetMs, 100);
      expect(formatOffset(-300), '−0.30 s');

      // Turning the sweep off leaves a plain highlighted line.
      await container.read(settingsProvider.notifier).setWordSweep(false);
      await tester.pump();
      expect(find.byType(SweepText), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sync editor times untimed lyrics and saves a version', (
      tester,
    ) async {
      final song = (await tester.runAsync(() async {
        final song = await addSong();
        await services.lyrics.importText(song.id, 'one\ntwo\nthree');
        return song;
      }))!;
      final events = StreamController<Object?>();
      addTearDown(events.close);
      final container = await pumpPlayer(tester, song, events);
      container.read(routerProvider).push('/player/sync');
      await tester.pumpAndSettle();
      expect(find.byType(LyricsSyncScreen), findsOneWidget);
      expect(find.text('3 lines left'), findsOneWidget);
      final save = find.widgetWithText(TextButton, 'Save');
      expect(tester.widget<TextButton>(save).onPressed, isNull);

      // Half speed while timing.
      await tester.tap(find.text('50%'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(backend.player['tempo'], 0.5);

      final tap = find.byKey(const ValueKey('sync-tap'));
      for (final position in [1000, 3000, 6000]) {
        await report(tester, events, position);
        await tester.tap(tap);
        await tester.pump();
      }
      expect(find.text('Every line is timed'), findsOneWidget);
      // Tap delay 40 ms; the fake engine reports tempo 1 in these events.
      expect(find.text('00:00.96'), findsOneWidget);
      expect(find.text('00:02.96'), findsOneWidget);

      // Nudge the last line 50 ms later, then undo it.
      await tester.tap(find.text('+50'));
      await tester.pump();
      expect(find.text('00:06.01'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(find.text('00:05.96'), findsOneWidget);

      await tester.tap(save);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LyricsSyncScreen), findsNothing);
      final doc = container.read(playerProvider).lyrics!;
      expect(doc.timed, isTrue);
      expect(
        [for (final l in doc.lines) l.time],
        [ms(960), ms(2960), ms(5960)],
      );
      final rows = await tester.runAsync(
        () => services.library.db.query('lyric_doc', orderBy: 'version'),
      );
      expect(
        [for (final row in rows!) row['source_kind']],
        ['paste', 'userEdited'],
      );
      // Leaving the editor restores normal speed.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(backend.player['tempo'], 1.0);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
