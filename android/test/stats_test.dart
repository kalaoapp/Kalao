import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/app.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/stats_screen.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// Favorites and stats.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': '0.1.0',
      }),
    });
    backend = FakeBackend()..install();
    services = await openTestServices();
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  Future<int> addSong(String title) => services.library.insertSong(
    NewSong(
      title: title,
      artist: 'A',
      durationMs: 200000,
      media: [
        NewMediaFile(
          kind: MediaKind.original,
          path: '/m/$title.mp3',
          sha256: 'sha-$title',
        ),
      ],
    ),
  );

  test('favorites mark songs, filter the list and go with the song', () async {
    final db = services.library;
    final a = await addSong('A');
    final b = await addSong('B');
    await db.setFavorite(b, true);
    await db.setFavorite(b, true); // idempotent
    expect(await db.isFavorite(b), isTrue);
    expect((await db.songs(favoritesOnly: true)).map((s) => s.id), [b]);
    expect((await db.song(b))!.favorite, isTrue);
    expect((await db.song(a))!.favorite, isFalse);
    await db.deleteSongs([b]);
    expect(await db.songs(favoritesOnly: true), isEmpty);
    await db.setFavorite(a, true);
    await db.setFavorite(a, false);
    expect(await db.isFavorite(a), isFalse);
  });

  test(
    'a version 1 library gains the favorite and backup_run tables',
    () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfiNoIsolate;
      final path = p.join(services.storage.root.path, 'v1.db');
      final v1 = await openVersionedDatabase(
        path,
        version: 1,
        migrations: libraryMigrations,
        factory: factory,
      );
      await v1.close();
      final upgraded = await LibraryDatabase.open(path, factory: factory);
      final tables = await upgraded.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((row) => row['name']),
        containsAll(<String>['favorite', 'backup_run']),
      );
      await upgraded.close();
    },
  );

  test('stats total plays, bucket days and rank songs', () async {
    final a = await addSong('A');
    final b = await addSong('B');
    final history = services.history;
    final now = DateTime(2026, 11, 17, 20);
    Future<void> play(int song, DateTime at, int minutes, PlayMode mode) async {
      final id = await history.startPlay(
        songId: song,
        songKey: 'k$song',
        mode: mode,
        now: at,
      );
      await history.finishPlay(id, listened: Duration(minutes: minutes));
    }

    await play(a, now, 3, PlayMode.karaoke);
    await play(a, now.subtract(const Duration(days: 1)), 4, PlayMode.learn);
    await play(b, now.subtract(const Duration(days: 2)), 10, PlayMode.learn);
    await play(b, now.subtract(const Duration(days: 30)), 1, PlayMode.karaoke);
    await play(a, now.subtract(const Duration(days: 40)), 1, PlayMode.karaoke);

    final stats = await history.stats(now: now);
    expect(stats.plays, 5);
    expect(stats.songs, 2);
    expect(stats.timeSung, const Duration(minutes: 19));
    expect(stats.days, hasLength(7));
    expect(stats.days.last.day, DateTime(2026, 11, 17));
    expect(stats.days.last.ms, const Duration(minutes: 3).inMilliseconds);
    expect(stats.days[5].plays, 1);
    expect(stats.days[4].ms, const Duration(minutes: 10).inMilliseconds);
    expect(stats.days.first.plays, 0);
    expect(stats.topSongs.first, (songId: a, value: 3));
    expect(stats.mostPractised.map((s) => s.songId), [b, a]);
    expect(stats.bestScores, isEmpty);
  });

  testWidgets('stats screen lists the most played songs', (tester) async {
    await tester.runAsync(() async {
      final id = await addSong('Moon');
      final play = await services.history.startPlay(
        songId: id,
        songKey: 'k',
        mode: PlayMode.karaoke,
      );
      await services.history.finishPlay(
        play,
        listened: const Duration(minutes: 2),
      );
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
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stats'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(StatsScreen), findsOneWidget);
    expect(find.text('Most played'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Moon'), findsOneWidget);
    expect(find.text('1 play'), findsOneWidget);
    expect(find.text('2 min'), findsWidgets);
  });

  test('listen time formats hours, minutes and seconds', () {
    expect(formatListenTime(const Duration(minutes: 65)), '1 h 5 min');
    expect(formatListenTime(const Duration(minutes: 12)), '12 min');
    expect(formatListenTime(const Duration(seconds: 40)), '40 s');
  });
}
