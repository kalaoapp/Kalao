import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/app.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/now_playing_screen.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/widgets/karaoke_lyrics_view.dart';
import 'package:kalao/widgets/lyric_line_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

Duration ms(int value) => Duration(milliseconds: value);

LyricLine line(String text, int time, {int? end, String? voice}) =>
    LyricLine.fromJson({
      'text': text,
      'timeMs': time,
      'endMs': ?end,
      'voice': ?voice,
    });

/// Intro of 6 s, two lines, a 7 s break, a last line.
LyricDocument song() => LyricDocument(
  timed: true,
  lines: [
    line('first', 6000, end: 8000),
    line('second', 8000, end: 10000),
    line('(ooh)', 8500, end: 9000, voice: backingVoice),
    line('after the break', 17000, end: 19000),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<Song> addSong(String title, {bool backing = true}) async {
    final id = await services.library.insertSong(
      NewSong(
        title: title,
        durationMs: 180000,
        media: [
          NewMediaFile(
            kind: MediaKind.original,
            path: '/m/$title-o.flac',
            sha256: '$title-o',
          ),
          if (backing)
            NewMediaFile(
              kind: MediaKind.instrumental,
              path: '/m/$title-i.flac',
              sha256: '$title-i',
            ),
        ],
      ),
    );
    return (await services.library.song(id))!;
  }

  Future<ProviderContainer> container() async {
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(services),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('karaoke frames: countdown after gaps, lines, the end', () {
    final doc = song();
    // The intro is a long gap: a note, then dots for the last four seconds.
    expect(KaraokeFrame.at(doc, 0), const KaraokeFrame(next: 0, dots: 0));
    expect(KaraokeFrame.at(doc, 2500), const KaraokeFrame(next: 0, dots: 4));
    expect(KaraokeFrame.at(doc, 5200), const KaraokeFrame(next: 0, dots: 1));
    // Singing: the current line and the next lead line (not the backing).
    expect(KaraokeFrame.at(doc, 6000), const KaraokeFrame(current: 0, next: 1));
    expect(KaraokeFrame.at(doc, 8700), const KaraokeFrame(current: 1, next: 3));
    // A 7 s break after the second line.
    expect(KaraokeFrame.at(doc, 10000), const KaraokeFrame(next: 3, dots: 0));
    expect(KaraokeFrame.at(doc, 14500), const KaraokeFrame(next: 3, dots: 3));
    expect(KaraokeFrame.at(doc, 17000), const KaraokeFrame(current: 3));
    expect(KaraokeFrame.at(doc, 19000), const KaraokeFrame(ended: true));
    // The offset shifts everything; a short gap has no countdown.
    expect(
      KaraokeFrame.at(doc.copyWith(offsetMs: 1000), 5000),
      const KaraokeFrame(current: 0, next: 1),
    );
    final close = LyricDocument(
      timed: true,
      lines: [line('a', 1000, end: 2000), line('b', 4000)],
    );
    expect(
      KaraokeFrame.at(close, 3000),
      const KaraokeFrame(current: 0, next: 1),
    );
  });

  test('the queue keeps its order, singers and modes', () async {
    final a = await addSong('a');
    final b = await addSong('b');
    final c = await addSong('c');
    final queue = services.queue;
    await queue.add(a.id, singer: ' Mei ');
    await queue.add(b.id, mode: PlayMode.learn);
    final last = await queue.add(c.id, singer: 'Ken');
    var items = await queue.items();
    expect([for (final item in items) item.songId], [a.id, b.id, c.id]);
    expect(items.first.singer, 'Mei');
    expect(items[1].mode, PlayMode.learn);

    await queue.move(2, 0);
    await queue.update(last, singer: 'Kenji', mode: PlayMode.learn);
    items = await queue.items();
    expect([for (final item in items) item.songId], [c.id, a.id, b.id]);
    expect(items.first.singer, 'Kenji');
    expect(items.first.mode, PlayMode.learn);

    expect((await queue.takeFirst())!.songId, c.id);
    await queue.removeSongs([a.id]);
    expect([for (final item in await queue.items()) item.songId], [b.id]);
    await queue.clear();
    expect(await queue.takeFirst(), isNull);
  });

  test('modes, key and tempo, loops and line stepping', () async {
    final providers = await container();
    final track = await addSong('track');
    await services.lyrics.save(track.id, song(), source: 'file');
    final player = providers.read(playerProvider.notifier);
    await player.playSong(track, mode: PlayMode.karaoke);
    expect(providers.read(playerProvider).isKaraoke, isTrue);
    expect(backend.player['vocalLevel'], 0.0);
    final plays = await services.history.db.query('play');
    expect(plays.single['mode'], 'karaoke');

    await player.setKey(-3);
    await player.setTempo(0.75);
    expect(backend.player['key'], -3);
    expect(backend.player['tempo'], 0.75);

    // Loop the line being sung (the fake engine is at 0: move into line 2).
    await player.seek(ms(8200));
    await player.toggleLineLoop();
    expect(backend.player['loopStartMs'], 8000);
    expect(backend.player['loopEndMs'], 10000);
    expect(backend.player['positionMs'], 8000);
    expect(providers.read(playerProvider).engine.looping, isTrue);
    await player.toggleLineLoop();
    expect(backend.player['loopStartMs'], isNull);

    // Long-press one line: it repeats at once.
    await player.holdLine(1);
    expect(providers.read(playerProvider).loopLines, (1, 1));
    expect(backend.player['loopStartMs'], 8000);
    expect(backend.player['loopEndMs'], 10000);
    expect(backend.player['positionMs'], 8000);
    // Another line next: everything between the two, in either order.
    await player.holdLine(0);
    expect(providers.read(playerProvider).loopLines, (0, 1));
    expect(providers.read(playerProvider).loopOpen, isFalse);
    expect(backend.player['loopStartMs'], 6000);
    expect(backend.player['loopEndMs'], 10000);
    // A line inside the repeat stops it; one outside starts a new one.
    await player.holdLine(0);
    expect(providers.read(playerProvider).loopLines, isNull);
    expect(backend.player['loopEndMs'], isNull);
    await player.holdLine(3);
    await player.holdLine(3);
    expect(providers.read(playerProvider).loopLines, isNull);
    await player.holdLine(0);
    await player.holdLine(3);
    expect(backend.player['loopEndMs'], 19000);
    await player.clearLoop();
    expect(backend.player['loopEndMs'], isNull);
    expect(providers.read(playerProvider).loopLines, isNull);

    // Stepping skips the backing line.
    await player.seek(ms(8200));
    await player.stepLine(1);
    expect(backend.player['positionMs'], 17000);
    await player.stepLine(-1);
    expect(backend.player['positionMs'], 8000);

    // A new song starts at normal speed in the original key, in Learn mode.
    await player.playSong(await addSong('other'));
    expect(backend.player['key'], 0);
    expect(backend.player['tempo'], 1);
    expect(providers.read(playerProvider).mode, PlayMode.learn);
    expect(backend.player['vocalLevel'], 1.0);
  });

  test('the next queued song starts when a song ends', () async {
    final events = StreamController<Object?>();
    addTearDown(events.close);
    final preferences = await SharedPreferences.getInstance();
    final providers = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(services, events: events.stream),
      ],
    );
    addTearDown(providers.dispose);
    final first = await addSong('first');
    final second = await addSong('second');
    final gone = await addSong('gone');
    final actions = providers.read(queueActionsProvider);
    await actions.add(gone);
    await actions.add(second, singer: 'Mei', mode: PlayMode.karaoke);
    await services.library.deleteSongs([gone.id]);
    expect(
      (await providers.read(queueProvider.future)).single.song.id,
      second.id,
    );

    await providers.read(playerProvider.notifier).playSong(first);
    events.add(
      jsonEncode({...backend.player, 'playing': false, 'completed': true}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final now = providers.read(playerProvider);
    expect(now.song?.id, second.id);
    expect(now.singer, 'Mei');
    expect(now.isKaraoke, isTrue);
    expect(await services.queue.items(), isEmpty);
    final plays = await services.history.db.query('play', orderBy: 'id');
    expect(plays.last['singer'], 'Mei');
  });

  test(
    'Japanese gets furigana and romaji; Chinese follows the variant',
    () async {
      final providers = await container();
      final japanese = await addSong('ja');
      final doc = await services.lyrics.importText(japanese.id, '桜が咲く');
      expect(doc.sourceLang, 'ja');
      final layers = doc.lines.single.layers;
      expect(layers[LyricLayerKind.furigana]!.segments.first.reading, 'さくら');
      expect(layers.containsKey(LyricLayerKind.pinyin), isFalse);
      expect(romajiOf(doc.lines.single), 'sakura ga sa ku');
      const settings = AppSettings();
      expect(rubyLayerFor(doc.lines.single, settings), LyricLayerKind.furigana);
      expect(
        rubyLayerFor(doc.lines.single, settings.copyWith(showFurigana: false)),
        isNull,
      );

      final chinese = await addSong('zh');
      await services.lyrics.importText(chinese.id, '我爱你\nhello');
      final player = providers.read(playerProvider.notifier);
      await player.playSong(chinese);
      expect(providers.read(playerProvider).lyrics!.lines.first.display, '我爱你');
      await providers
          .read(settingsProvider.notifier)
          .setChineseVariant(ChineseVariant.traditional);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final lines = providers.read(playerProvider).lyrics!.lines;
      expect(lines.first.display, '我愛你');
      // The stored text and its readings are untouched.
      expect(lines.first.text, '我爱你');
      expect(lines.first.layers[LyricLayerKind.pinyin], isNotNull);
      expect(lines.last.variantText, isNull);
      expect(
        (await services.library.lyrics(chinese.id))!.lines.first.text,
        '我爱你',
      );
      // Japanese lyrics are never converted.
      await player.playSong(japanese);
      expect(
        providers.read(playerProvider).lyrics!.lines.single.variantText,
        isNull,
      );
    },
  );

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Stream<Object?>? events,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          ...testOverrides(services, events: events),
        ],
        child: const KalaoApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
  }

  testWidgets('Karaoke mode shows two lines, a countdown and the next singer', (
    tester,
  ) async {
    final (track, next) = (await tester.runAsync(() async {
      final track = await addSong('track');
      await services.lyrics.save(track.id, song(), source: 'file');
      return (track, await addSong('encore'));
    }))!;
    final events = StreamController<Object?>();
    addTearDown(events.close);
    final providers = await pumpApp(tester, events: events.stream);
    await tester.runAsync(() async {
      await providers.read(queueActionsProvider).add(next, singer: 'Mei');
      await providers
          .read(playerProvider.notifier)
          .playSong(track, mode: PlayMode.karaoke);
    });
    providers.read(routerProvider).push('/player');

    Future<void> at(int positionMs) async {
      events.add(
        jsonEncode({
          ...backend.player,
          'positionMs': positionMs,
          'playing': false,
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await at(3500);
    expect(find.byType(KaraokeLyricsView), findsOneWidget);
    // Three seconds before the first line: three dots, the line waiting.
    expect(find.byIcon(Icons.circle), findsNWidgets(3));
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);

    await at(6500);
    expect(find.byIcon(Icons.circle), findsNothing);
    expect(find.text('first'), findsWidgets);
    expect(find.text('second'), findsOneWidget);

    await at(19500);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(find.text('Next up'), findsOneWidget);
    expect(find.text('Mei'), findsOneWidget);
    expect(find.text('encore'), findsOneWidget);

    // S switches to the original; Learn mode brings the scrolling lyrics.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    expect(backend.player['vocalLevel'], 1.0);
    await tester.tap(find.text('Learn'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.byType(KaraokeLyricsView), findsNothing);
    expect(find.byType(LyricsView), findsOneWidget);
    // No repeat button: long-pressing a line starts one.
    expect(find.text('Stop repeating'), findsNothing);
    expect(find.text('75%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the queue tab lists, edits and plays entries', (tester) async {
    final (a, b) = (await tester.runAsync(
      () async => (await addSong('alpha'), await addSong('beta')),
    ))!;
    final providers = await pumpApp(tester);
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('The queue is empty'), findsOneWidget);

    await tester.runAsync(() async {
      final actions = providers.read(queueActionsProvider);
      await actions.add(a, singer: 'Mei');
      await actions.add(b, mode: PlayMode.learn);
      await providers.read(queueProvider.future);
    });
    await tester.pumpAndSettle();
    expect(find.byType(QueueTab), findsOneWidget);
    expect(find.text('Mei · Karaoke'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'beta'), findsOneWidget);
    expect(find.text('Learn'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove from queue').first);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await providers.read(queueProvider.future);
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'alpha'), findsNothing);

    // Tapping an entry sings it now, in its mode.
    await tester.tap(find.widgetWithText(ListTile, 'beta'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(providers.read(playerProvider).song?.id, b.id);
    expect(providers.read(playerProvider).mode, PlayMode.learn);
    expect(await tester.runAsync(services.queue.items), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('What\'s New shows once after an update; ? opens the help', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': '0.0.9',
      }),
    });
    final track = (await tester.runAsync(() => addSong('track')))!;
    final providers = await pumpApp(tester);
    expect(find.text("What's new in 0.1.0"), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Recently added'), findsOneWidget);
    expect(providers.read(settingsProvider).whatsNewVersion, '0.1.0');
    expect(
      initialLocationForAppState(
        setupCompleted: true,
        tutorialSeen: false,
        whatsNewVersion: null,
      ),
      '/tutorial',
    );

    await tester.runAsync(
      () => providers.read(playerProvider.notifier).playSong(track),
    );
    providers.read(routerProvider).push('/player');
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Repeat the current line'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
