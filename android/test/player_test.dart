import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/app.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/now_playing_screen.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/playback_handler.dart';
import 'package:kalao/widgets/ruby_lyric_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

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
        'whatsNewVersion': AppInfo.version,
      }),
    });
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  Future<Song> addSong({bool backing = true}) async {
    final id = await services.library.insertSong(
      NewSong(
        title: '月亮代表我的心',
        artist: '邓丽君',
        durationMs: 180000,
        media: [
          const NewMediaFile(
            kind: MediaKind.original,
            path: '/m/o.flac',
            sha256: 'o',
          ),
          if (backing)
            const NewMediaFile(
              kind: MediaKind.instrumental,
              path: '/m/i.flac',
              sha256: 'i',
            ),
        ],
      ),
    );
    return (await services.library.song(id))!;
  }

  test('deck interpolates between position events while playing', () async {
    final events = StreamController<Object?>();
    final deck = KaraokeDeck(events: events.stream)..start();
    events.add(
      jsonEncode({'positionMs': 1000, 'playing': true, 'durationMs': 5000}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(deck.position, greaterThan(const Duration(milliseconds: 1040)));
    expect(deck.position, lessThan(const Duration(milliseconds: 1500)));
    events.add(
      jsonEncode({'positionMs': 2000, 'playing': false, 'durationMs': 5000}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(deck.position, const Duration(milliseconds: 2000));
    await deck.dispose();
    await events.close();
  });

  test(
    'deck interpolates from the instant the engine took its state',
    () async {
      var now = const Duration(seconds: 10);
      final events = StreamController<Object?>();
      final deck = KaraokeDeck(events: events.stream, now: () => now)..start();
      // Taken 100 ms ago, delivered late: the position allows for the delay.
      events.add({
        'state': jsonEncode({'positionMs': 1000, 'playing': true}),
        'atMicros': (now - const Duration(milliseconds: 100)).inMicroseconds,
      });
      await Future<void>.delayed(Duration.zero);
      expect(deck.position, const Duration(milliseconds: 1100));
      // A stamp from another clock (too old) falls back to the arrival time.
      events.add({
        'state': jsonEncode({'positionMs': 2000, 'playing': true}),
        'atMicros': 5,
      });
      await Future<void>.delayed(Duration.zero);
      expect(deck.position, const Duration(milliseconds: 2000));
      now += const Duration(milliseconds: 50);
      expect(deck.position, const Duration(milliseconds: 2050));
      await deck.dispose();
      await events.close();
    },
  );

  test('the lock screen is updated on changes, not on every report', () async {
    final handler = KalaoAudioHandler();
    final published = <PlaybackState>[];
    final subscription = handler.playbackState.listen(published.add);
    final moon = Song(
      id: 1,
      title: 'Moon',
      songKey: 'k',
      addedAt: DateTime(2026),
    );
    const playing = EnginePlayerState(
      songId: '1',
      playing: true,
      durationMs: 100000,
    );
    handler.publish(moon, playing);
    for (var ms = 33; ms < 300; ms += 33) {
      handler.publish(
        moon,
        EnginePlayerState(
          songId: '1',
          playing: true,
          durationMs: 100000,
          positionMs: ms,
        ),
      );
    }
    handler.publish(
      moon,
      const EnginePlayerState(songId: '1', durationMs: 100000, positionMs: 300),
    );
    handler.publish(
      moon,
      const EnginePlayerState(
        songId: '1',
        durationMs: 100000,
        positionMs: 60000,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // The initial state (BehaviorSubject seed), play, pause, the seek.
    expect(published, hasLength(4));
    expect(published.last.updatePosition, const Duration(minutes: 1));
    await subscription.cancel();
  });

  test(
    'playing a song loads both tracks, switches, keeps history and session',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          ...testOverrides(services),
        ],
      );
      addTearDown(container.dispose);
      final song = await addSong();
      final controller = container.read(playerProvider.notifier);
      await controller.playSong(song, start: const Duration(seconds: 12));

      final load = backend.calls.firstWhere(
        (call) => call.method == 'playerLoad',
      );
      final args = FakeBackend.argsOf(load);
      expect(args['startMs'], 12000);
      expect([
        for (final source in args['sources'] as List) (source as Map)['kind'],
      ], unorderedEquals(['original', 'instrumental']));
      expect(backend.player['playing'], isTrue);

      // A song opens in Learn mode with the original vocals.
      expect(container.read(playerProvider).mode, PlayMode.learn);
      expect(backend.player['vocalLevel'], 1.0);
      await controller.setInstrumental(true);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerProvider).isInstrumental, isTrue);
      // Karaoke mode is remembered for the song and plays the backing track.
      await controller.setInstrumental(false);
      await controller.setMode(PlayMode.karaoke);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerProvider).isInstrumental, isTrue);
      expect((await services.library.song(song.id))!.lastMode, 'karaoke');

      await controller.setVocalLevel(0.3);
      expect(backend.player['vocalLevel'], 0.3);

      await controller.seek(const Duration(seconds: 40));
      await controller.stop();
      expect(await services.history.recentlyPlayedSongIds(), [song.id]);
      final session = await services.appState.session();
      expect(session['songId'], '${song.id}');
      expect(container.read(playerProvider).song, isNull);
    },
  );

  test('continue singing follows the song just started', () async {
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(services),
      ],
    );
    addTearDown(container.dispose);
    final first = await addSong();
    final second = await addSong(backing: false);
    final controller = container.read(playerProvider.notifier);
    final listener = container.listen(continueSingingProvider, (_, _) {});
    addTearDown(listener.close);

    await controller.playSong(first);
    await controller.playSong(second);
    final resume = await container.read(continueSingingProvider.future);
    expect(resume?.song.id, second.id);
  });

  test('a song without an instrumental cannot switch', () async {
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(services),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(playerProvider.notifier);
    await controller.playSong(await addSong(backing: false));
    await Future<void>.delayed(Duration.zero);
    await controller.setInstrumental(true);
    expect(
      backend.calls.where((c) => c.method == 'playerSwitchTrack'),
      isEmpty,
    );
  });

  testWidgets('landscape puts the controls beside the lyrics', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final song = (await tester.runAsync(() async {
      final song = await addSong();
      await services.lyrics.importText(song.id, 'one\ntwo\nthree');
      return song;
    }))!;
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          ...testOverrides(services),
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
    container.read(routerProvider).push('/player');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final lyrics = tester.getRect(find.byType(LyricsView));
    final controls = tester.getRect(find.byType(PlayerControls));
    expect(controls.left, greaterThanOrEqualTo(lyrics.right));
    // The lyrics keep the full body height (the screen is ~393 dp tall).
    expect(lyrics.height, greaterThan(300));
  });

  testWidgets('now playing shows pinyin and steps untimed lines', (
    tester,
  ) async {
    final song = (await tester.runAsync(() async {
      final song = await addSong();
      await services.lyrics.importText(song.id, '[Verse]\n月亮\n你好\nlast line');
      return song;
    }))!;
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          ...testOverrides(services),
        ],
        child: const KalaoApp(),
      ),
    );
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(MaterialApp).first);
    final container = ProviderScope.containerOf(element);
    await tester.runAsync(
      () => container.read(playerProvider.notifier).playSong(song),
    );
    container.read(routerProvider).push('/player');
    await tester.pumpAndSettle();

    expect(find.text('Verse'), findsOneWidget);
    expect(find.text('yuè'), findsOneWidget);
    expect(find.text('hǎo'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Instrumental'), findsWidgets);

    expect(container.read(playerProvider).manualLine, 0);
    await tester.tap(find.byTooltip('Next line'));
    await tester.pump();
    expect(container.read(playerProvider).manualLine, 1);
    await tester.ensureVisible(find.text('last line'));
    await tester.pump();
    await tester.tap(find.text('last line'));
    await tester.pump();
    expect(container.read(playerProvider).manualLine, 2);

    // Turning pinyin off leaves plain text.
    await container.read(settingsProvider.notifier).setShowPinyin(false);
    await tester.pumpAndSettle();
    expect(find.text('yuè'), findsNothing);
    expect(find.byType(RubyLyricLine), findsNWidgets(3));

    await tester.tap(find.text('Instrumental').first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(backend.player['vocalLevel'], 0.0);
    final doc = container.read(playerProvider).lyrics!;
    expect(doc.timed, isFalse);
    expect(doc.lines.first.layers.containsKey(LyricLayerKind.pinyin), isTrue);
  });

  testWidgets('home search finds a song by pinyin', (tester) async {
    await tester.runAsync(() async {
      final song = await addSong();
      await services.importer.refreshSearchKeys([song.id]);
    });
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          ...testOverrides(services),
        ],
        child: const KalaoApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recently added'), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'yueliang');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '月亮代表我的心'), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No songs match'), findsOneWidget);
  });
}
