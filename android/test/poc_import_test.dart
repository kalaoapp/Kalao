import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/poc_import_service.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// A `kalao-poc.json` export attaches to songs already imported.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;

  setUp(() async {
    backend = FakeBackend()..install();
    services = await openTestServices();
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  String export() => jsonEncode({
    'format': 'kalao-poc',
    'version': 1,
    'exportedAt': '2026-11-01T00:00:00Z',
    'songs': [
      {
        'title': '月亮代表我的心',
        'artist': '邓丽君',
        'favorite': true,
        'lines': [
          {'text': '你好', 'translation': 'Hello'},
          {'text': ''},
          {'text': '月亮', 'translation': 'Moon', 'sectionBreak': true},
        ],
        'plays': [
          {'at': '2026-10-01T10:00:00Z', 'track': 'instrumental'},
          {'at': 'not a date'},
        ],
      },
      {
        'title': '夜に駆ける',
        'artist': 'YOASOBI',
        'lines': [
          {'text': '沈むように', 'furigana': 'しずむように'},
        ],
      },
      {'title': 'Missing Song', 'artist': 'Nobody', 'lines': <Object?>[]},
    ],
  });

  Future<int> add(String title, String artist) => services.library.insertSong(
    NewSong(
      title: title,
      artist: artist,
      media: [
        NewMediaFile(kind: MediaKind.original, path: '/$title', sha256: title),
      ],
    ),
  );

  test('lyrics, furigana, favorites and plays attach by title', () async {
    final moon = await add('月亮代表我的心 ', '邓丽君');
    final yoru = await add('夜に駆ける', 'YOASOBI');
    final service = PocImportService(services);

    final result = await service.importJson(export());
    expect(result.matched, 2);
    expect(result.lyrics, 2);
    expect(result.favorites, 1);
    expect(result.plays, 1);
    expect(result.unmatched, ['Missing Song · Nobody']);

    final lyrics = (await services.library.lyrics(moon))!;
    expect(lyrics.lines.map((l) => l.text), ['你好', '月亮']);
    expect(lyrics.lines.map((l) => l.translation), ['Hello', 'Moon']);
    expect(lyrics.lines[1].sectionBreakBefore, isTrue);
    expect(lyrics.lines[0].layers.containsKey(LyricLayerKind.pinyin), isTrue);
    expect((await services.library.song(moon))!.favorite, isTrue);

    final furigana = (await services.library.lyrics(
      yoru,
    ))!.lines.single.layers[LyricLayerKind.furigana]!;
    expect(furigana.origin, LayerOrigin.human);
    expect(furigana.segments.single.reading, 'しずむように');

    // Running it again adds no duplicate plays.
    await service.importJson(export());
    expect((await services.history.stats()).plays, 1);
  });

  test('other files are refused', () async {
    final service = PocImportService(services);
    for (final text in ['nope', '{}', '{"format":"kalao-poc","version":2}']) {
      await expectLater(
        service.importJson(text),
        throwsA(isA<PocImportException>()),
      );
    }
  });
}
