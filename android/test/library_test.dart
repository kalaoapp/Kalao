import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_search.dart';
import 'package:kalao/widgets/ruby_lyric_line.dart';
import 'package:path/path.dart' as p;

import 'support/fake_backend.dart';
import 'support/test_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;

  setUp(() async {
    backend = FakeBackend()..install();
    services = await openTestServices(
      convert: (input, output) async {
        await File(output).writeAsBytes(await File(input).readAsBytes());
        return true;
      },
    );
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  NewSong song(String title, {String artist = 'A'}) => NewSong(
    title: title,
    artist: artist,
    durationMs: 200000,
    media: [
      NewMediaFile(
        kind: MediaKind.original,
        path: '/m/$title.mp3',
        sha256: 'sha-$title',
      ),
    ],
  );

  group('LibraryDatabase', () {
    test('songs round-trip with media, sort and duplicate lookup', () async {
      final db = services.library;
      final first = await db.insertSong(song('Zebra'), now: DateTime(2026));
      final second = await db.insertSong(
        song('Apple', artist: 'B'),
        now: DateTime(2027),
      );
      expect((await db.songs()).map((s) => s.id), [second, first]);
      expect((await db.songs(sort: SongSort.title)).map((s) => s.title), [
        'Apple',
        'Zebra',
      ]);
      expect(await db.songIdForSha('sha-Apple'), second);
      expect(await db.songIdForSha('nope'), isNull);
      await db.setMedia(
        first,
        const NewMediaFile(
          kind: MediaKind.instrumental,
          path: '/m/i.mp3',
          sha256: 'i',
        ),
      );
      final loaded = (await db.song(first))!;
      expect(loaded.hasBacking, isTrue);
      expect(loaded.file(MediaKind.instrumental)!.path, '/m/i.mp3');
      await db.deleteSongs([first]);
      expect(await db.song(first), isNull);
      expect(await db.isShaUsed('i'), isFalse, reason: 'media rows cascade');
    });

    test('lyrics keep layers per version and prune old versions', () async {
      final db = services.library;
      final id = await db.insertSong(song('Moon'));
      const doc = LyricDocument(
        lines: [
          LyricLine(text: '月亮', section: 'chorus'),
          LyricLine(text: 'hello', sectionBreakBefore: true),
        ],
      );
      for (var i = 0; i < LibraryDatabase.keptLyricVersions + 2; i++) {
        await db.saveLyrics(
          id,
          doc,
          sourceKind: 'paste',
          layers: {
            0: {
              LyricLayerKind.pinyin: const LyricLayer(
                segments: [
                  RubySegment(0, 1, 'yuè'),
                  RubySegment(1, 2, 'liang'),
                ],
              ),
            },
          },
        );
      }
      final loaded = (await db.lyrics(id))!;
      expect(loaded.lines.first.section, 'chorus');
      expect(loaded.lines[1].sectionBreakBefore, isTrue);
      expect(loaded.lines.first.layers[LyricLayerKind.pinyin]!.segments, const [
        RubySegment(0, 1, 'yuè'),
        RubySegment(1, 2, 'liang'),
      ]);
      final versions = await db.db.rawQuery(
        'SELECT version FROM lyric_doc WHERE song_id = ?',
        [id],
      );
      expect(versions, hasLength(LibraryDatabase.keptLyricVersions));
      expect((await db.song(id))!.hasLyrics, isTrue);
    });

    test('search matches keys by prefix first, then substring', () async {
      final db = services.library;
      final moon = await db.insertSong(song('月亮代表我的心'));
      final other = await db.insertSong(song('Blue Moon'));
      await db.replaceSearchKeys(
        [moon, other],
        [
          {
            'songId': moon,
            'keyKind': 'pinyin',
            'key': 'yueliangdaibiaowodexin',
          },
          {'songId': moon, 'keyKind': 'title', 'key': '月亮代表我的心'},
          {'songId': other, 'keyKind': 'title', 'key': 'bluemoon'},
          {'songId': other, 'keyKind': 'artist', 'key': 'yueliangfan'},
        ],
      );
      expect((await db.search('YueLiang')).map((s) => s.id), [other, moon]);
      expect((await db.search('月亮')).map((s) => s.id), [moon]);
      expect((await db.search('moon')).map((s) => s.id), [other]);
      expect(await db.search('%'), isEmpty);
      expect(await db.search('  '), isEmpty);
    });

    test('song keys prefer ISRC and round the duration', () {
      expect(
        LibraryDatabase.songKey('A', 'B', 1000, ' us1234 '),
        'isrc:US1234',
      );
      expect(
        LibraryDatabase.songKey('Hello!', 'Ad Ele', 201000, null),
        LibraryDatabase.songKey('hello', 'adele', 199000, null),
      );
    });
  });

  test('history lists recent songs once, newest first', () async {
    final history = services.history;
    await history.startPlay(
      songId: 1,
      songKey: 'a',
      mode: PlayMode.listen,
      now: DateTime(2026),
    );
    final id = await history.startPlay(
      songId: 2,
      songKey: 'b',
      mode: PlayMode.listen,
      now: DateTime(2027),
    );
    await history.startPlay(
      songId: 1,
      songKey: 'a',
      mode: PlayMode.karaoke,
      now: DateTime(2028),
    );
    await history.finishPlay(id, listened: const Duration(seconds: 30));
    expect(await history.recentlyPlayedSongIds(), [1, 2]);
    await history.forgetSongs([1]);
    expect(await history.recentlyPlayedSongIds(), [2]);
  });

  test('search normalisation matches the Rust rule', () {
    // Same cases as kalao_core::search_keys tests.
    expect(normalizeSearchText("Don't Stop — Me Now"), 'dontstopmenow');
    expect(normalizeSearchText('邓丽君 Teresa Teng'), '邓丽君teresateng');
    expect(normalizeSearchText('Ai Otsuka!'), 'aiotsuka');
  });

  group('ImportService', () {
    Future<File> write(String name, String content) async {
      final file = File(p.join(services.storage.root.path, 'picked', name));
      await file.create(recursive: true);
      await file.writeAsString(content);
      return file;
    }

    Future<List<int>> importFiles(Map<String, String> files) async {
      final importer = services.importer;
      final staged = [
        for (final MapEntry(:key, :value) in files.entries)
          await importer.stage(key, (await write(key, value)).openRead()),
      ];
      final proposals = await importer.propose(staged);
      return importer.commit(proposals);
    }

    test(
      'pairs, copies by hash, imports lyrics with pinyin and search keys',
      () async {
        final ids = await importFiles({
          '月亮.mp3': 'original audio',
          '月亮 (伴奏).mp3': 'backing audio',
          '月亮.txt': '[Chorus]\n月亮\n\n你好',
        });
        expect(ids, hasLength(1));
        final song = (await services.library.song(ids.single))!;
        expect(song.title, '月亮');
        expect(song.hasBacking, isTrue);
        for (final file in song.media) {
          expect(p.dirname(file.path), services.storage.media.path);
          expect(p.basenameWithoutExtension(file.path), file.sha256);
          expect(File(file.path).existsSync(), isTrue);
        }
        final lyrics = (await services.library.lyrics(song.id))!;
        expect(lyrics.lines.map((l) => l.text), ['月亮', '你好']);
        expect(lyrics.lines.first.section, 'chorus');
        expect(lyrics.lines[1].sectionBreakBefore, isTrue);
        expect(
          lyrics.lines[1].layers[LyricLayerKind.pinyin]!.segments.map(
            (s) => s.reading,
          ),
          ['nǐ', 'hǎo'],
        );
        expect((await services.library.search('yueliang')).single.id, song.id);
        expect(services.storage.importStaging.existsSync(), isFalse);
      },
    );

    test('flags duplicates and skips them by default', () async {
      await importFiles({'Song.mp3': 'same bytes'});
      final importer = services.importer;
      final staged = [
        await importer.stage(
          'Copy.mp3',
          (await write('Copy.mp3', 'same bytes')).openRead(),
        ),
      ];
      final proposals = await importer.propose(staged);
      expect(proposals.single.duplicateOf, isNotNull);
      expect(proposals.single.include, isFalse);
      expect(await importer.commit(proposals), isEmpty);
    });

    test('converts files the engine cannot decode', () async {
      final ids = await importFiles({'Track.opus': 'opus data'});
      final song = (await services.library.song(ids.single))!;
      expect(p.extension(song.media.single.path), '.flac');
      expect(Directory(services.storage.media.path).listSync(), hasLength(1));
    });

    test('deleting songs removes their unused media', () async {
      final ids = await importFiles({'Gone.mp3': 'gone'});
      final song = (await services.library.song(ids.single))!;
      await services.importer.deleteSongs([song]);
      expect(File(song.media.single.path).existsSync(), isFalse);
    });

    test('lyrics import rejects empty documents', () async {
      final id = await services.library.insertSong(song('Empty'));
      await expectLater(
        services.lyrics.importText(id, '\n\n'),
        throwsA(anything),
      );
    });
  });

  group('lyrics model', () {
    test('active line uses start times and the offset', () {
      const doc = LyricDocument(
        timed: true,
        offsetMs: 500,
        lines: [
          LyricLine(text: 'a', time: Duration(seconds: 1)),
          LyricLine(text: 'b', time: Duration(seconds: 3)),
          LyricLine(text: 'c', time: Duration(seconds: 5)),
        ],
      );
      expect(doc.activeLineAt(Duration.zero), isNull);
      expect(doc.activeLineAt(const Duration(milliseconds: 600)), 0);
      expect(doc.activeLineAt(const Duration(milliseconds: 2600)), 1);
      expect(doc.activeLineAt(const Duration(seconds: 9)), 2);
      expect(
        const LyricDocument(
          lines: [LyricLine(text: 'x')],
        ).activeLineAt(Duration.zero),
        isNull,
      );
    });

    test('ruby units align readings and keep plain words whole', () {
      expect(
        RubyLyricLine.units('我 love 你', const [
          RubySegment(0, 1, 'wǒ'),
          RubySegment(7, 8, 'nǐ'),
        ]),
        [('我', 'wǒ'), (' ', null), ('love ', null), ('你', 'nǐ')],
      );
      expect(
        RubyLyricLine.units('哪儿好', const [
          RubySegment(0, 2, 'nǎr'),
          RubySegment(2, 3, 'hǎo'),
        ]),
        [('哪儿', 'nǎr'), ('好', 'hǎo')],
      );
      // Out-of-range segments are ignored rather than crashing.
      expect(RubyLyricLine.units('ab', const [RubySegment(1, 5, 'x')]), [
        ('ab', null),
      ]);
    });
  });
}
