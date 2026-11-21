import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/models/library_folder.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_folder_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_folder_service.dart';
import 'package:kalao/utils/document_tree.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

const tree =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;
  late Directory disk;
  late LibraryFolderService folders;

  setUp(() async {
    backend = FakeBackend()..install();
    services = await openTestServices();
    folders = services.folders;
    disk = await Directory.systemTemp.createTemp('kalao-folder-');
    backend.musicFolders[tree] = {};
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
    if (disk.existsSync()) await disk.delete(recursive: true);
  });

  var tick = 0;

  /// Writes [path] (below the music folder) with [content] and a new
  /// modification time.
  File put(String path, [String content = 'audio']) {
    final file = File(p.join(disk.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    file.setLastModifiedSync(
      DateTime(2026, 1, 1).add(Duration(minutes: tick++)),
    );
    backend.musicFolders[tree]![path] = file;
    return file;
  }

  String uri(String path) => FakeBackend.folderUri(tree, path);

  Future<LibraryFolder> added() => folders.addFolder(tree);

  int probes() => backend.calls.where((c) => c.method == 'probeAudio').length;

  group('document trees', () {
    test('names and overlap', () {
      expect(treeId(tree), 'primary:Music');
      expect(treeFolderName(tree), 'Music');
      expect(treeFolderName('$tree%2FKaraoke'), 'Music/Karaoke');
      expect(
        treeFolderName(
          'content://com.android.externalstorage.documents/tree/primary%3A',
        ),
        'primary',
      );
      expect(treesOverlap(tree, '$tree%2FKaraoke'), isTrue);
      expect(treesOverlap('$tree%2FKaraoke', tree), isTrue);
      expect(treesOverlap(tree, '${tree}2'), isFalse);
      expect(
        treesOverlap(
          'content://com.android.externalstorage.documents/tree/primary%3A',
          tree,
        ),
        isTrue,
      );
    });

    test(
      'a folder inside a music folder is refused; the same one returns',
      () async {
        final folder = await added();
        expect((await folders.addFolder(tree)).id, folder.id);
        await expectLater(
          folders.addFolder('$tree%2FKaraoke'),
          throwsA(isA<FolderOverlapException>()),
        );
      },
    );
  });

  group('scan', () {
    test(
      'adds songs in place with instrumental and lyrics from the same directory',
      () async {
        put('Pop/Moon.mp3');
        put('Pop/Moon (Instrumental).mp3');
        put('Pop/Moon.lrc', '[00:01.00]月亮');
        put('Rock/Sun.flac');
        final folder = await added();
        final result = await folders.scan(folder);
        expect(result.added, hasLength(2));
        final songs = await services.library.songs(sort: SongSort.title);
        expect(songs.map((s) => s.title), ['Moon', 'Sun']);
        final moon = songs.first;
        expect(moon.file(MediaKind.original)!.path, uri('Pop/Moon.mp3'));
        expect(
          moon.file(MediaKind.instrumental)!.path,
          uri('Pop/Moon (Instrumental).mp3'),
        );
        expect(moon.media.every((f) => f.inFolder && f.sha256.isEmpty), isTrue);
        expect(moon.hasLyrics, isTrue);
        expect(await services.library.lyricsSourceKind(moon.id), folderSource);
        final rows = await services.library.db.query('media_file');
        expect(rows.map((r) => r['source']).toSet(), {folderSource});
        // Searchable like any song, and every descriptor was closed.
        expect(await services.library.search('sun'), hasLength(1));
        expect(backend.openDocuments, isEmpty);
        final listed = (await folders.folders()).single;
        expect(listed.songs, 2);
        expect(listed.scannedAt, isNotNull);
      },
    );

    test('a scan with nothing changed reads no file', () async {
      put('Moon.mp3');
      final folder = await added();
      await folders.scan(folder);
      final before = probes();
      final result = await folders.scan(folder);
      expect(result.changed, isFalse);
      expect(probes(), before);
    });

    test(
      'a changed lyrics file replaces folder lyrics but not edited ones',
      () async {
        put('Moon.mp3');
        put('Moon.lrc', '[00:01.00]one');
        final folder = await added();
        await folders.scan(folder);
        final id = (await services.library.songs()).single.id;

        put('Moon.lrc', '[00:01.00]two');
        expect((await folders.scan(folder)).updated, 1);
        expect((await services.library.lyrics(id))!.lines.single.text, 'two');

        final doc = (await services.library.lyrics(id))!;
        await services.lyrics.save(id, doc, source: 'userEdited');
        put('Moon.lrc', '[00:01.00]three');
        await folders.scan(folder);
        expect((await services.library.lyrics(id))!.lines.single.text, 'two');
      },
    );

    test(
      'a new lyrics file or instrumental joins a song already there',
      () async {
        put('Moon.mp3');
        final folder = await added();
        await folders.scan(folder);
        put('Moon.lrc', '[00:01.00]月亮');
        put('Moon (Karaoke).mp3');
        final result = await folders.scan(folder);
        expect(result.added, isEmpty);
        final song = (await services.library.songs()).single;
        expect(song.hasLyrics, isTrue);
        expect(song.hasBacking, isTrue);
      },
    );

    test(
      'removed files leave the library; a renamed original keeps its pair',
      () async {
        put('Moon.mp3');
        put('Moon (Instrumental).mp3');
        put('Sun.mp3');
        final folder = await added();
        await folders.scan(folder);

        backend.musicFolders[tree]!.remove('Sun.mp3');
        final renamed = backend.musicFolders[tree]!.remove('Moon.mp3')!;
        backend.musicFolders[tree]!['Moon .mp3'] = renamed;
        final result = await folders.scan(folder);
        expect(result.removed, 2);
        expect(result.added, hasLength(1));
        final song = (await services.library.songs()).single;
        expect(song.file(MediaKind.original)!.path, uri('Moon .mp3'));
        expect(song.hasBacking, isTrue);

        backend.musicFolders[tree]!.remove('Moon (Instrumental).mp3');
        await folders.scan(folder);
        expect((await services.library.songs()).single.hasBacking, isFalse);
      },
    );

    test('a deleted song stays out and its file stays on disk', () async {
      final file = put('Moon.mp3');
      final folder = await added();
      await folders.scan(folder);
      await services.importer.deleteSongs(await services.library.songs());
      expect(file.existsSync(), isTrue);
      expect((await folders.scan(folder)).added, isEmpty);
      expect(await services.library.songs(), isEmpty);
    });

    test('a folder Kalao cannot read keeps its songs', () async {
      put('Moon.mp3');
      final folder = await added();
      await folders.scan(folder);
      backend.musicFolders.remove(tree);
      final result = await folders.scan(folder);
      expect(result.lostAccess, isTrue);
      expect(await services.library.songs(), hasLength(1));
      expect((await folders.folders()).single.accessLost, isTrue);

      backend.musicFolders[tree] = {
        'Moon.mp3': File(p.join(disk.path, 'Moon.mp3')),
      };
      await folders.scan(folder);
      expect((await folders.folders()).single.accessLost, isFalse);
    });

    test(
      'files the engine cannot play in place or read are listed as skipped',
      () async {
        put('Moon.opus');
        put('Sun.mp3');
        put('Star.mp3');
        backend.failing['probeAudio'] = 'cannot read';
        final folder = await added();
        expect((await folders.scan(folder)).skipped, 3);
        backend.failing.remove('probeAudio');
        // Unchanged skipped files are not read again; a changed one is.
        put('Sun.mp3', 'fixed');
        final result = await folders.scan(folder);
        expect(result.added, hasLength(1));
        put('Moon.opus', 'still opus');
        await folders.scan(folder);
        final skipped = await folders.skipped((await folders.folders()).single);
        expect(skipped.map((f) => (f.name, f.reason)), [
          ('Moon.opus', 'format'),
          ('Star.mp3', 'unreadable'),
        ]);
        expect((await folders.folders()).single.skipped, 2);
      },
    );

    test(
      'a cancelled scan stops between files and the next one goes on',
      () async {
        put('A.mp3');
        put('B.mp3');
        final folder = await added();
        var reads = 0;
        final first = await folders.scan(
          folder,
          cancelled: () => reads > 0,
          onProgress: (done, total) => reads = done,
        );
        expect(first.cancelled, isTrue);
        expect(first.added, isEmpty);
        expect((await folders.scan(folder)).added, hasLength(2));
      },
    );

    test('removing a folder removes its songs and keeps the files', () async {
      final file = put('Moon.mp3');
      final folder = await added();
      await folders.scan(folder);
      expect(await folders.removeFolder(folder), 1);
      expect(await services.library.songs(), isEmpty);
      expect(await folders.folders(), isEmpty);
      expect(file.existsSync(), isTrue);
    });
  });

  group('controller', () {
    test('adds, scans and removes a picked folder', () async {
      put('Moon.mp3');
      backend.nextTreeUri = tree;
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          ...testOverrides(services),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(libraryFoldersProvider.notifier);
      final result = await controller.pickAndAdd();
      expect(result!.added, hasLength(1));
      final state = container.read(libraryFoldersProvider);
      expect(state.scanning, isFalse);
      expect(state.folders.single.songs, 1);
      expect(
        backend.calls.map((c) => c.method),
        containsAllInOrder(['startBackgroundWork', 'stopBackgroundWork']),
      );
      await controller.remove(state.folders.single);
      expect(container.read(libraryFoldersProvider).folders, isEmpty);
      expect(backend.releasedTrees, [tree]);
    });
  });

  test(
    'the deck plays folder files through descriptors and closes the old ones',
    () async {
      put('Moon.mp3');
      put('Sun.mp3');
      final deck = KaraokeDeck(events: const Stream.empty());
      await deck.load(songId: '1', sources: {'original': uri('Moon.mp3')});
      final load = backend.calls.lastWhere((c) => c.method == 'playerLoad');
      final sources =
          (jsonDecode(load.arguments as String) as Map)['sources'] as List;
      expect((sources.single as Map)['path'], endsWith('Moon.mp3'));
      expect(backend.openDocuments.values, [uri('Moon.mp3')]);
      await deck.load(songId: '2', sources: {'original': uri('Sun.mp3')});
      expect(backend.openDocuments.values, [uri('Sun.mp3')]);
      await deck.dispose();
    },
  );
}
