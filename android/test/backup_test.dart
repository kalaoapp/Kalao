import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_folder_store.dart';
import 'package:kalao/services/library_queue_store.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// Backup export, preview, Merge and Replace restore.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices phone;
  late LibraryServices tablet;
  late Directory out;

  setUp(() async {
    backend = FakeBackend()..install();
    phone = await openTestServices();
    tablet = await openTestServices();
    out = await Directory.systemTemp.createTemp('kalao-backups-');
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(phone);
    await closeTestServices(tablet);
    await out.delete(recursive: true);
  });

  BackupService backupOf(LibraryServices services) =>
      BackupService(services, factory: databaseFactoryFfiNoIsolate);

  /// A song whose audio really is in [services]' media folder.
  Future<int> addSong(
    LibraryServices services,
    String title, {
    String audio = 'audio',
  }) async {
    final file = File(p.join(services.storage.media.path, 'sha-$title.mp3'));
    await file.writeAsString(audio);
    final cover = File(p.join(services.storage.covers.path, 'c-$title.jpg'));
    await cover.writeAsString('jpeg');
    return services.library.insertSong(
      NewSong(
        title: title,
        artist: 'Singer',
        durationMs: 200000,
        coverPath: cover.path,
        media: [
          NewMediaFile(
            kind: MediaKind.original,
            path: file.path,
            sha256: 'sha-$title',
          ),
        ],
      ),
    );
  }

  LyricDocument doc(List<String> lines) =>
      LyricDocument(lines: [for (final text in lines) LyricLine(text: text)]);

  Map<int, Map<LyricLayerKind, LyricLayer>> pinyin(
    int line,
    String reading,
    LayerOrigin origin,
  ) => {
    line: {
      LyricLayerKind.pinyin: LyricLayer(
        segments: [RubySegment(0, 1, reading)],
        origin: origin,
      ),
    },
  };

  Future<String> backUp(
    LibraryServices services, {
    AppSettings settings = const AppSettings(),
    bool includeMedia = true,
  }) async {
    final path = p.join(
      out.path,
      '${DateTime.now().microsecondsSinceEpoch}.kalaobackup',
    );
    await backupOf(
      services,
    ).create(outputPath: path, settings: settings, includeMedia: includeMedia);
    return path;
  }

  test('settings in a backup leave out this device\'s keys', () {
    const settings = AppSettings(
      setupCompleted: true,
      customFontPath: '/data/fonts/a.ttf',
      backupFolderUri: 'content://tree/x',
      backupSchedule: BackupSchedule.daily,
      showRomaji: true,
    );
    final json = settings.toBackupJson();
    expect(json.keys.toSet().intersection(AppSettings.deviceKeys), isEmpty);
    expect(json['showRomaji'], isTrue);

    const device = AppSettings(
      setupCompleted: true,
      backupFolderUri: 'content://tree/tablet',
    );
    final restored = AppSettings.restoredFrom({
      ...json,
      'backupFolderUri': 'content://tree/phone',
    }, device);
    expect(restored.showRomaji, isTrue);
    expect(restored.backupFolderUri, 'content://tree/tablet');
    expect(restored.setupCompleted, isTrue);
    expect(restored.customFontPath, isNull);
  });

  test('Replace moves a whole library to another device', () async {
    final song = await addSong(phone, 'Moon');
    await phone.lyrics.importText(song, '你好\nworld');
    await phone.library.setFavorite(song, true);
    final play = await phone.history.startPlay(
      songId: song,
      songKey: (await phone.library.song(song))!.songKey,
      mode: PlayMode.learn,
      singer: 'Ann',
    );
    await phone.history.finishPlay(play, listened: const Duration(minutes: 3));
    await phone.queue.add(song, singer: 'Ann');
    final backup = await backUp(
      phone,
      settings: const AppSettings(showRomaji: true, customFontPath: '/x.ttf'),
    );

    await addSong(tablet, 'Old song'); // replaced
    final service = backupOf(tablet);
    final staged = await service.inspect(backup);
    expect(staged.preview.songs, 1);
    expect(staged.preview.newSongs, 1);
    expect(staged.preview.plays, 1);
    expect(staged.preview.favorites, 1);
    expect(staged.preview.withLyrics, 1);
    expect(staged.preview.mediaFiles, 1);
    expect(staged.preview.appVersion, '0.1.0');

    const tabletSettings = AppSettings(
      setupCompleted: true,
      backupFolderUri: 'content://tree/tablet',
    );
    final result = await service.restore(
      staged,
      RestoreMode.replace,
      current: tabletSettings,
    );
    expect(staged.dir.existsSync(), isFalse);
    expect(result.settings!.showRomaji, isTrue);
    expect(result.settings!.customFontPath, isNull);
    expect(result.settings!.backupFolderUri, 'content://tree/tablet');

    final songs = await tablet.library.songs();
    expect(songs.map((s) => s.title), ['Moon']);
    final moon = songs.single;
    expect(moon.favorite, isTrue);
    expect(
      moon.media.single.path,
      p.join(tablet.storage.media.path, 'sha-Moon.mp3'),
    );
    expect(await File(moon.media.single.path).readAsString(), 'audio');
    expect(p.dirname(moon.coverPath!), tablet.storage.covers.path);
    expect(File(moon.coverPath!).existsSync(), isTrue);
    final lyrics = await tablet.library.lyrics(moon.id);
    expect(lyrics!.lines.map((l) => l.text), ['你好', 'world']);
    expect((await tablet.history.stats()).plays, 1);
    expect((await QueueStore(tablet.appState.db).items()).single.singer, 'Ann');
    // The tablet's own data went into a safety backup first.
    expect(
      tablet.storage.safetyBackups.listSync().whereType<File>(),
      hasLength(1),
    );
  });

  test('music-folder songs keep their documents and are not copied', () async {
    const uri = 'content://docs/tree/primary%3AMusic/document/Sun.mp3';
    final folder = await phone.folders.addFolder(
      'content://docs/tree/primary%3AMusic',
    );
    final sun = await phone.library.insertSong(
      const NewSong(
        title: 'Sun',
        media: [
          NewMediaFile(
            kind: MediaKind.original,
            path: uri,
            sha256: '',
            source: 'folder',
          ),
        ],
      ),
    );
    await phone.folders.store.putFile(
      FolderFile(
        uri: uri,
        folderId: folder.id,
        name: 'Sun.mp3',
        role: FolderFileRole.original,
        songId: sun,
      ),
    );
    await addSong(phone, 'Moon');
    final backup = await backUp(phone);

    final service = backupOf(tablet);
    final staged = await service.inspect(backup);
    expect(staged.preview.mediaFiles, 1);
    expect(staged.preview.missingMedia, 0);
    await service.restore(
      staged,
      RestoreMode.replace,
      current: const AppSettings(),
    );
    final restored = (await tablet.library.songs(sort: SongSort.title)).last;
    expect(restored.title, 'Sun');
    expect(restored.media.single.path, uri);
    expect((await tablet.folders.folders()).single.songs, 1);
  });

  test('Merge matches songs, keeps human layers and unions plays', () async {
    // Both devices have "Moon"; the phone edited its lyrics later.
    final phoneSong = await addSong(phone, 'Moon');
    await phone.library.saveLyrics(
      phoneSong,
      doc(['月亮', 'new second line']),
      sourceKind: 'user',
      now: DateTime(2026, 11, 10),
    );
    await phone.library.setFavorite(phoneSong, true);
    final key = (await phone.library.song(phoneSong))!.songKey;
    final played = await phone.history.startPlay(
      songId: phoneSong,
      songKey: key,
      mode: PlayMode.karaoke,
      now: DateTime(2026, 11, 11),
    );
    await phone.history.finishPlay(
      played,
      listened: const Duration(minutes: 2),
    );
    final onlyOnPhone = await addSong(phone, 'Sun');
    await phone.lyrics.importText(onlyOnPhone, 'sunshine');

    final tabletSong = await addSong(tablet, 'Moon');
    await tablet.library.saveLyrics(
      tabletSong,
      doc(['月亮', 'old second line']),
      sourceKind: 'user',
      layers: {
        ...pinyin(0, 'yuè (mine)', LayerOrigin.human),
        ...pinyin(1, 'x', LayerOrigin.human),
      },
      now: DateTime(2026, 11, 1),
    );
    await tablet.history.startPlay(
      songId: tabletSong,
      songKey: key,
      mode: PlayMode.karaoke,
      now: DateTime(2026, 11, 12),
    );

    final backup = await backUp(phone);
    final service = backupOf(tablet);
    var staged = await service.inspect(backup);
    expect(staged.preview.songs, 2);
    expect(staged.preview.newSongs, 1);
    final result = await service.restore(
      staged,
      RestoreMode.merge,
      current: const AppSettings(),
    );
    expect(result.settings, isNull);
    expect(result.addedSongs, hasLength(1));

    final songs = await tablet.library.songs(sort: SongSort.title);
    expect(songs.map((s) => s.title), ['Moon', 'Sun']);
    expect(songs.first.id, tabletSong);
    expect(songs.first.favorite, isTrue);
    expect(
      File(songs.last.media.single.path).parent.path,
      tablet.storage.media.path,
    );

    // The phone's newer text wins; the tablet's human reading stays on the
    // unchanged first line but not on the rewritten second line.
    final lyrics = (await tablet.library.lyrics(tabletSong))!;
    expect(lyrics.lines.map((l) => l.text), ['月亮', 'new second line']);
    expect(
      lyrics.lines[0].layers[LyricLayerKind.pinyin]!.segments.single.reading,
      'yuè (mine)',
    );
    expect(lyrics.lines[1].layers, isEmpty);
    expect(
      (await tablet.library.lyrics(songs.last.id))!.lines.single.text,
      'sunshine',
    );

    // Plays are unioned once, even when the same backup is restored again.
    expect((await tablet.history.stats()).plays, 2);
    staged = await service.inspect(backup);
    await service.restore(
      staged,
      RestoreMode.merge,
      current: const AppSettings(),
    );
    expect((await tablet.history.stats()).plays, 2);
    expect(await tablet.library.songs(), hasLength(2));
  });

  test('older library wins when its lyrics are newer', () async {
    final phoneSong = await addSong(phone, 'Moon');
    await phone.library.saveLyrics(
      phoneSong,
      doc(['old']),
      sourceKind: 'user',
      now: DateTime(2026),
    );
    final tabletSong = await addSong(tablet, 'Moon');
    await tablet.library.saveLyrics(
      tabletSong,
      doc(['newer']),
      sourceKind: 'user',
      now: DateTime(2027),
    );
    final service = backupOf(tablet);
    await service.restore(
      await service.inspect(await backUp(phone)),
      RestoreMode.merge,
      current: const AppSettings(),
    );
    expect(
      (await tablet.library.lyrics(tabletSong))!.lines.single.text,
      'newer',
    );
  });

  test(
    'a backup without media restores songs that point to missing audio',
    () async {
      await addSong(phone, 'Moon');
      final service = backupOf(tablet);
      final staged = await service.inspect(
        await backUp(phone, includeMedia: false),
      );
      expect(staged.preview.mediaFiles, 0);
      expect(staged.preview.missingMedia, 1);
      await service.restore(
        staged,
        RestoreMode.merge,
        current: const AppSettings(),
      );
      final song = (await tablet.library.songs()).single;
      expect(File(song.media.single.path).existsSync(), isFalse);
      expect(File(song.coverPath!).existsSync(), isTrue);
    },
  );

  test('a Replace that fails part-way puts the current data back', () async {
    await addSong(phone, 'Moon');
    await addSong(tablet, 'Sun');
    final service = backupOf(tablet);
    final staged = await service.inspect(await backUp(phone));
    // The history database goes missing after the check: the library is
    // replaced, then the history step fails.
    await File(staged.historyDb).delete();
    await expectLater(
      service.restore(
        staged,
        RestoreMode.replace,
        current: const AppSettings(),
      ),
      throwsA(anything),
    );
    final songs = await tablet.library.songs();
    expect(songs.map((song) => song.title), ['Sun']);
  });

  test('backups from a newer schema or another app are refused', () async {
    await addSong(phone, 'Moon');
    final backup = await backUp(phone);
    // Rewrite the library snapshot as a future schema version.
    final archive = (jsonDecode(await File(backup).readAsString()) as Map)
        .cast<String, Object?>();
    final files = (archive['files']! as Map).cast<String, String>();
    final dbPath = p.join(out.path, 'future.db');
    await File(dbPath).writeAsBytes(base64Decode(files['library.db']!));
    final db = await databaseFactoryFfiNoIsolate.openDatabase(dbPath);
    await db.execute('PRAGMA user_version = ${libraryVersion + 1}');
    await db.close();
    files['library.db'] = base64Encode(await File(dbPath).readAsBytes());
    await File(backup).writeAsString(jsonEncode({...archive, 'files': files}));

    final service = backupOf(tablet);
    await expectLater(
      service.inspect(backup),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('newer'),
        ),
      ),
    );
    expect(tablet.storage.backupWork.listSync(), isEmpty);

    final junk = File(p.join(out.path, 'junk.kalaobackup'))
      ..writeAsStringSync('nope');
    await expectLater(
      service.inspect(junk.path),
      throwsA(isA<BackupException>()),
    );
  });

  test('file names sort by time and match the pruning pattern', () {
    final name = BackupService.fileName(DateTime(2026, 3, 4, 5, 6));
    expect(name, 'kalao-2026-03-04-0506.kalaobackup');
    expect(BackupService.fileNamePattern.hasMatch(name), isTrue);
    expect(
      BackupService.fileNamePattern.hasMatch('other.kalaobackup'),
      isFalse,
    );
  });
}
