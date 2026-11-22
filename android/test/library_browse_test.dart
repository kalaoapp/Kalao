import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/app.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/library/library_pages.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/utils/folder_cover.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// Browsing, filters, search, maintenance and playlists (FEATURES 6.11–6.14).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': AppInfo.version,
      }),
    });
    backend = FakeBackend()..install();
    services = await openTestServices();
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  Future<int> add(
    String title, {
    String artist = 'Teresa',
    String album = '',
    String? albumArtist,
    String? genre,
    int? year,
    int? track,
    int? disc,
    String codec = 'mp3',
    String source = 'import',
    int bytes = 100,
    bool instrumental = false,
    int durationMs = 200000,
    String? isrc,
    DateTime? now,
  }) => services.library.insertSong(
    NewSong(
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      isrc: isrc,
      tags: SongTags(
        albumArtist: albumArtist,
        genre: genre,
        year: year,
        trackNo: track,
        discNo: disc,
      ),
      media: [
        NewMediaFile(
          kind: MediaKind.original,
          path: source == 'folder'
              ? 'content://tree/doc/$title.$codec'
              : '/m/$title.$codec',
          sha256: source == 'folder' ? '' : 'sha-$title',
          codec: codec,
          bytes: bytes,
          source: source,
        ),
        if (instrumental)
          NewMediaFile(
            kind: MediaKind.instrumental,
            path: '/m/$title-inst.mp3',
            sha256: 'sha-$title-inst',
          ),
      ],
    ),
    now: now,
  );

  Future<List<String>> titles(SongQuery query) async => [
    for (final song in await services.browse.page(query, limit: 1000))
      song.title,
  ];

  group('browse', () {
    test('sorts, pages and counts', () async {
      await add('B', year: 2001, bytes: 5, now: DateTime(2026, 1, 2));
      await add('A', year: 1999, bytes: 50, now: DateTime(2026, 1, 3));
      await add('C', now: DateTime(2026, 1, 1));
      expect(await titles(const SongQuery()), ['A', 'B', 'C']);
      expect(await titles(const SongQuery(sort: LibrarySort.oldest)), [
        'C',
        'B',
        'A',
      ]);
      expect(await titles(const SongQuery(sort: LibrarySort.year)), [
        'B',
        'A',
        'C',
      ]);
      expect(await titles(const SongQuery(sort: LibrarySort.size)), [
        'C',
        'A',
        'B',
      ]);
      expect(await services.browse.count(const SongQuery()), 3);
      final second = await services.browse.page(
        const SongQuery(sort: LibrarySort.title),
        offset: 1,
        limit: 1,
      );
      expect(second.single.title, 'B');
    });

    test('reads more songs than SQLite allows in one IN list', () async {
      await services.library.db.transaction((txn) async {
        for (var i = 0; i < 1200; i++) {
          final id = await txn.insert('song', {
            'title': 'Song $i',
            'song_key': 'k$i',
            'added_at': i,
          });
          await txn.insert('media_file', {
            'song_id': id,
            'kind': 'original',
            'path': '/m/$i.mp3',
            'sha256': 's$i',
          });
        }
      });
      final ids = await services.browse.ids(const SongQuery());
      expect(ids, hasLength(1200));
      final songs = await services.library.songsByIds(ids);
      expect(songs, hasLength(1200));
      expect(songs.every((song) => song.media.length == 1), isTrue);
    });

    test('filters for karaoke', () async {
      final timed = await add('Timed', instrumental: true, codec: 'flac');
      final plain = await add('Plain', source: 'folder', genre: 'Pop');
      await add('Bare', year: 2000);
      await services.library.saveLyrics(
        timed,
        LyricDocument(
          timed: true,
          lines: [
            LyricLine(
              text: 'one two',
              time: const Duration(seconds: 1),
              words: const [LyricWord(text: 'one', time: Duration(seconds: 1))],
            ),
          ],
        ),
        sourceKind: 'user',
      );
      await services.library.saveLyrics(
        plain,
        const LyricDocument(lines: [LyricLine(text: 'la la')]),
        sourceKind: 'user',
      );
      await services.library.setFavorite(plain, true);

      Future<List<String>> where(SongQuery query) => titles(query);
      expect(await where(const SongQuery(lyrics: LyricsFilter.none)), ['Bare']);
      expect(await where(const SongQuery(lyrics: LyricsFilter.plain)), [
        'Plain',
      ]);
      expect(await where(const SongQuery(lyrics: LyricsFilter.words)), [
        'Timed',
      ]);
      expect(await where(const SongQuery(hasInstrumental: true)), ['Timed']);
      expect(await where(const SongQuery(codec: 'FLAC')), ['Timed']);
      expect(await where(const SongQuery(origin: SongOrigin.folder)), [
        'Plain',
      ]);
      expect(
        await where(const SongQuery(origin: SongOrigin.imported)),
        unorderedEquals(['Timed', 'Bare']),
      );
      expect(await where(const SongQuery(favoritesOnly: true)), ['Plain']);
      expect(
        await where(const SongQuery(missingGenre: true, missingYear: true)),
        ['Timed'],
      );
      expect(await services.browse.codecs(), ['flac', 'mp3']);

      await services.library.setAvailable([
        'content://tree/doc/Plain.mp3',
      ], false);
      expect(await where(const SongQuery(unavailableOnly: true)), ['Plain']);
      final song = (await services.library.songsByIds([plain])).single;
      expect(song.unavailable, isTrue);
      expect(song.playable, isFalse);
    });

    test('albums in disc and track order, artists and genres', () async {
      await add('Two', album: 'Light', albumArtist: 'Teresa', track: 2);
      await add('One', album: 'light', albumArtist: 'Teresa', track: 1);
      await add(
        'Bonus',
        album: 'Light',
        albumArtist: 'Teresa',
        disc: 2,
        track: 1,
      );
      await add('Other', album: 'Light', artist: 'Someone', genre: 'Pop/Rock');
      await add('Solo', artist: 'Someone', genre: 'pop; Ballad');

      final albums = await services.browse.albums();
      expect(albums, hasLength(2));
      final light = albums.firstWhere((a) => a.ref.artist == 'Teresa');
      expect(light.songs, 3);
      expect(await titles(SongQuery(album: light.ref)), [
        'One',
        'Two',
        'Bonus',
      ]);

      final artists = await services.browse.artists();
      expect([for (final a in artists) a.name], ['Someone', 'Teresa']);
      expect(
        await titles(
          const SongQuery(artist: 'someone', sort: LibrarySort.title),
        ),
        ['Other', 'Solo'],
      );
      expect(await services.browse.albums(artist: 'Someone'), hasLength(1));

      final genres = await services.browse.genres();
      expect(
        {for (final g in genres) g.key: g.songs},
        {'ballad': 1, 'pop': 2, 'rock': 1},
      );
      expect(
        await titles(const SongQuery(genre: 'pop', sort: LibrarySort.title)),
        ['Other', 'Solo'],
      );
    });

    test('folder levels count everything below them', () async {
      final folder = await services.library.db.insert('library_folder', {
        'tree_uri': 'content://tree/x',
        'name': 'Music',
        'added_at': 0,
      });
      Future<void> file(String dir, String title) async {
        final id = await add(title, source: 'folder');
        await services.library.db.insert('folder_file', {
          'uri': 'content://tree/doc/$title.mp3',
          'folder_id': folder,
          'dir': dir,
          'name': '$title.mp3',
          'role': 'original',
          'song_id': id,
        });
      }

      await file('', 'Top');
      await file('Pop', 'P1');
      await file('Pop/Live', 'P2');
      await file('Rock', 'R1');
      final top = await services.browse.folderLevel(folder, '');
      expect(top.songs, 1);
      expect(
        [for (final d in top.dirs) (d.name, d.songs)],
        [('Pop', 2), ('Rock', 1)],
      );
      final pop = await services.browse.folderLevel(folder, 'Pop');
      expect(pop.dirs.single.dir, 'Pop/Live');
      expect(
        await titles(
          SongQuery(folder: FolderRef(folder, 'Pop'), sort: LibrarySort.title),
        ),
        ['P1', 'P2'],
      );
      expect(
        [
          for (final s in await services.browse.folderSongs(
            FolderRef(folder, 'Pop'),
          ))
            s.title,
        ],
        ['P1'],
      );
    });
  });

  group('search', () {
    test('every word in any order, pinyin included, and lyric lines', () async {
      final moon = await add('月亮代表我的心', artist: '邓丽君');
      await add('Sweet Dreams', artist: 'Eurythmics');
      await services.importer.refreshSearchKeys();
      expect(
        [
          for (final s in await services.library.search('dreams sweet'))
            s.title,
        ],
        ['Sweet Dreams'],
      );
      expect([
        for (final s in await services.library.search('sweet, nightmares'))
          s.title,
      ], isEmpty);
      expect(
        [for (final s in await services.library.search('liang yue')) s.id],
        [moon],
      );
      await services.lyrics.importText(moon, '你问我爱你有多深\n我爱你有几分');
      expect(
        [for (final s in await services.library.searchLyrics('爱你有多深')) s.id],
        [moon],
      );
      expect(await services.library.searchLyrics('nothing like this'), isEmpty);
    });

    test('known keys mark extension results that are in the library', () async {
      await add('Moon', isrc: 'usabc1234567');
      final key = LibraryDatabase.songKey('Moon', 'Teresa', 200000, null);
      final isrc = LibraryDatabase.songKey('x', 'y', 1, 'USABC1234567');
      expect(await services.browse.knownKeys([key, isrc]), {isrc});
    });
  });

  group('maintenance', () {
    test(
      'keeping a duplicate moves lyrics, favorites, plays and playlists',
      () async {
        final kept = await add('Moon', source: 'folder');
        final copy = await add('Moon');
        await services.lyrics.importText(copy, 'copy lyrics');
        await services.library.setFavorite(copy, true);
        final play = await services.history.startPlay(
          songId: copy,
          songKey: 'k',
          mode: PlayMode.karaoke,
        );
        await services.history.finishPlay(play, listened: Duration.zero);
        final list = await services.playlists.create('Party');
        await services.playlists.add(list, [copy]);

        final groups = await services.maintenance.duplicateGroups();
        expect(groups.single.map((s) => s.id), [kept, copy]);
        await services.maintenance.keep(groups.single.first, groups.single);

        final song = (await services.library.songs()).single;
        expect(song.id, kept);
        expect(song.hasLyrics, isTrue);
        expect(song.favorite, isTrue);
        expect(await services.history.recentlyPlayedSongIds(), [kept]);
        expect(
          [
            for (final item in await services.playlists.items(list))
              item.songId,
          ],
          [kept],
        );
        expect(await services.maintenance.duplicateGroups(), isEmpty);
      },
    );

    test('artwork lookups are remembered and removals stick', () async {
      await add('One', album: 'Light');
      await add('Two', album: 'Light');
      final maintenance = services.maintenance;
      final missing = await maintenance.albumsMissingArtwork();
      expect(missing.single.ref.name, 'Light');
      final cover = File(p.join(services.storage.covers.path, 'found.jpg'))
        ..writeAsStringSync('jpeg');
      await maintenance.applyCover(missing.single.ref, cover.path);
      expect(
        (await services.library.songs()).every(
          (s) => s.coverPath == cover.path,
        ),
        isTrue,
      );
      await maintenance.removeCover(missing.single.ref);
      expect(
        (await services.library.songs()).every((s) => s.coverPath == null),
        isTrue,
      );
      expect(cover.existsSync(), isFalse);
      // Removed: not looked up again.
      expect(await maintenance.albumsMissingArtwork(), isEmpty);
    });
  });

  group('playlists', () {
    test('add, reorder, remove, and a Merge restore joins by name', () async {
      final a = await add('A');
      final b = await add('B');
      final store = services.playlists;
      final id = await store.create('Party');
      await store.add(id, [a, b, a]);
      var items = await store.items(id);
      expect([for (final i in items) i.songId], [a, b, a]);
      await store.reorder(id, [
        items[2].itemId,
        items[0].itemId,
        items[1].itemId,
      ]);
      items = await store.items(id);
      expect([for (final i in items) i.songId], [a, a, b]);
      await store.removeItem(id, items.first.itemId);
      expect((await store.playlists()).single.songs, 2);

      final tablet = await openTestServices();
      addTearDown(() => closeTestServices(tablet));
      final tabletB = await tablet.library.insertSong(
        const NewSong(
          title: 'B',
          artist: 'Teresa',
          durationMs: 200000,
          media: [],
        ),
      );
      final tabletParty = await tablet.playlists.create('party');
      await tablet.playlists.add(tabletParty, [tabletB]);

      final out = await Directory.systemTemp.createTemp('kalao-pl-');
      addTearDown(() => out.delete(recursive: true));
      final path = p.join(out.path, 'b.kalaobackup');
      await BackupService(
        services,
        factory: databaseFactoryFfiNoIsolate,
      ).create(
        outputPath: path,
        settings: const AppSettings(),
        includeMedia: false,
      );
      final restorer = BackupService(
        tablet,
        factory: databaseFactoryFfiNoIsolate,
      );
      await restorer.restore(
        await restorer.inspect(path),
        RestoreMode.merge,
        current: const AppSettings(),
      );
      final lists = await tablet.playlists.playlists();
      expect(lists.single.name, 'party');
      final merged = [
        for (final song in await tablet.library.songsByIds([
          for (final i in await tablet.playlists.items(lists.single.id))
            i.songId,
        ]))
          song.title,
      ];
      expect(merged, ['B', 'A']);
    });
  });

  test('folder images follow Mornye\'s rules', () {
    expect(folderImage(['album.png', 'Folder.JPG', 'front.jpg']), 'Folder.JPG');
    expect(folderImage(['COVER.PNG', 'cover.webp', 'folder.jpg']), 'COVER.PNG');
    expect(folderImage(['._cover.jpg', 'song.flac']), isNull);
    expect(isDiscFolder('CD1'), isTrue);
    expect(isDiscFolder('Disc 2 - Live'), isTrue);
    expect(isDiscFolder('Disk 02'), isTrue);
    expect(isDiscFolder('CDs'), isFalse);
    expect(isDiscFolder('Discography'), isFalse);
  });

  testWidgets('the Library opens on the last view and browses albums', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await add('One', album: 'Light', albumArtist: 'Teresa', track: 1);
      await add('Two', album: 'Light', albumArtist: 'Teresa', track: 2);
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
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlbumsView), findsOneWidget);
    await tester.tap(find.text('Light'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlbumScreen), findsOneWidget);
    expect(find.text('Sing all'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AlbumScreen)),
    );
    expect(container.read(settingsProvider).libraryTab, LibraryTab.albums);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
