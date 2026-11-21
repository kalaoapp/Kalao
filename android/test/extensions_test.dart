import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/extensions/extension_detail_screen.dart';
import 'package:kalao/screens/extensions/extension_install.dart';
import 'package:kalao/screens/extensions/extensions_tab.dart';
import 'package:kalao/screens/shared_files.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/extension_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/lyrics_language_guess.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

const _token = {'key': 'token', 'type': 'secret', 'label': 'API token'};
const _region = {
  'key': 'region',
  'type': 'select',
  'label': 'Region',
  'options': ['jp', 'tw'],
  'default': 'jp',
};

/// Extensions (M5): the Dart side over a fake extension manager.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;
  late MemorySecretStore secrets;
  late ExtensionService service;

  setUp(() async {
    backend = FakeBackend()..install();
    services = await openTestServices();
    secrets = MemorySecretStore();
    service = ExtensionService(
      storage: services.storage,
      library: services.library,
      importer: services.importer,
      secrets: secrets,
    );
  });

  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  Map<String, Object?> argsOf(String method) => FakeBackend.argsOf(
    backend.calls.lastWhere((call) => call.method == method),
  );

  test('start hands stored secrets to Rust; secret settings stay out of '
      'Rust storage and extension-set secrets reach secure storage', () async {
    backend.addExtension(
      FakeBackend.extensionInfo('dev.test.a', settings: [_token, _region]),
    );
    secrets.values[ExtensionService.secretKey('dev.test.a', 'token')] = 'tok';
    final installed = await service.start();
    expect(installed.single.id, 'dev.test.a');
    expect(argsOf('extensionsInit')['root'], services.storage.extensions.path);
    expect(argsOf('setExtensionSecrets'), {
      'id': 'dev.test.a',
      'values': {'token': 'tok'},
    });

    final extension = (await service.list()).extensions.single;
    final token = extension.manifest.settings.first;
    await service.setSetting(extension, token, 'new-token');
    expect(
      secrets.values[ExtensionService.secretKey('dev.test.a', 'token')],
      'new-token',
    );
    await service.setSetting(extension, token, '');
    expect(secrets.values, isEmpty);

    backend.secretUpdates['dev.test.a'] = {'token': 'refreshed'};
    await service.list();
    expect(
      secrets.values[ExtensionService.secretKey('dev.test.a', 'token')],
      'refreshed',
    );
    await service.uninstall(extension);
    expect(secrets.values, isEmpty);
    expect(backend.extensions, isEmpty);
  });

  test('actions open the login pages the extension asks for and callbacks '
      'are delivered', () async {
    backend.addExtension(FakeBackend.extensionInfo('dev.test.a'));
    backend.authRequests.add({
      'extensionId': 'dev.test.a',
      'url': 'https://example.org/login',
    });
    final opened = <String>[];
    final extension = (await service.list()).extensions.single;
    final result = await service.runAction(
      extension,
      const ExtensionSetting(
        key: 'login',
        type: ExtensionSettingType.button,
        label: 'Log in',
      ),
      (url) async => opened.add(url),
    );
    expect(result, 'done');
    expect(opened, ['https://example.org/login']);

    backend.extensionCallbacks.add('kalao://ext/dev.test.a/callback?code=1');
    await service.deliverCallbacks();
    expect(argsOf('extensionAuthCallback'), {
      'url': 'kalao://ext/dev.test.a/callback?code=1',
    });
  });

  test('lyrics from an extension are parsed, annotated for their language '
      'and saved with their source', () async {
    final id = await services.library.insertSong(
      const NewSong(title: '月亮', media: []),
    );
    final saved = await service.importLyrics(
      id,
      const LyricsCandidate(
        extensionId: 'dev.test.lrc',
        extensionName: 'LRC',
        id: '7',
        format: 'lrc',
        body: '[00:01.00]月亮\n[00:03.00]你好',
        language: 'zh-Hant',
      ),
    );
    expect(saved.sourceLang, 'zh');
    expect(saved.source?.extensionId, 'dev.test.lrc');
    expect(argsOf('annotateLyrics')['layers'], ['pinyin']);
    final stored = await services.library.lyrics(id);
    expect(stored!.source?.itemId, '7');
    expect(stored.lines.first.layers, isNotEmpty);
    final row = await services.library.db.query('lyric_doc');
    expect(row.single['source_kind'], 'extension');

    // English lyrics get no reading layers and no annotate call.
    final calls = backend.calls.length;
    final english = await service.importLyrics(
      id,
      const LyricsCandidate(
        extensionId: 'dev.test.lrc',
        extensionName: 'LRC',
        id: '8',
        format: 'plain',
        body: 'hello moon',
        language: 'en',
      ),
    );
    expect(english.sourceLang, 'en');
    expect(
      backend.calls.skip(calls).where((c) => c.method == 'annotateLyrics'),
      isEmpty,
    );
  });

  test('automatic lyric fetch takes a good match only', () async {
    final id = await services.library.insertSong(
      const NewSong(title: 'Moon', media: []),
    );
    final song = (await services.library.song(id))!;
    backend.lyricsCandidates.add({
      'extensionId': 'dev.test.lrc',
      'extensionName': 'LRC',
      'id': '1',
      'format': 'lrc',
      'body': '[00:01.00]moon',
      'score': 0.4,
    });
    expect(await service.autoFetchLyrics(song), isFalse);
    backend.lyricsCandidates.first['score'] = 1.2;
    expect(await service.autoFetchLyrics(song), isTrue);
    expect(await services.library.lyrics(id), isNotNull);
  });

  test('the language guess picks scripts and common words', () {
    expect(guessLyricsLanguage(['月亮代表我的心' * 8, '们这说为来时个爱会过']), 'zh-Hans');
    expect(guessLyricsLanguage(['きみのことがすきです' * 6]), 'ja');
    expect(guessLyricsLanguage(['short']), isNull);
  });

  test('a metadata result becomes an extension song that streams, then '
      'downloads into the library', () async {
    backend.addExtension(
      FakeBackend.extensionInfo(
        'dev.test.music',
        capabilities: ['metadata', 'audio'],
      ),
    );
    backend.audioSources.addAll([
      {'kind': 'original', 'url': 'https://cdn.example.org/1.mp3'},
      {'kind': 'instrumental', 'url': 'https://cdn.example.org/1i.mp3'},
    ]);
    const track = TrackResult(
      extensionId: 'dev.test.music',
      extensionName: 'Music',
      id: 't1',
      title: 'Moon',
      artists: ['Teresa'],
      durationMs: 200000,
    );
    final song = await service.addTrack(track);
    expect(song.streams, isTrue);
    expect(song.extRef?.trackId, 't1');
    expect((await service.addTrack(track)).id, song.id);

    final streams = await service.resolveStreams(song.extRef!);
    expect(streams.map((s) => s.source.kind), ['original', 'instrumental']);
    expect(streams.first.cacheKey, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(
      streams.first.cacheKey,
      ExtensionService.cacheKey('dev.test.music', 't1', 'original'),
    );

    await service.download(song, fetchLyrics: false);
    final downloaded = (await services.library.song(song.id))!;
    expect(downloaded.streams, isFalse);
    expect(downloaded.media.map((m) => m.kind), {
      MediaKind.original,
      MediaKind.instrumental,
    });
    final sources = await services.library.db.query(
      'media_file',
      columns: ['source'],
    );
    expect(sources.map((row) => row['source']).toSet(), {'extension'});
  });

  test('playing an extension song streams it; without an audio extension '
      'the player reports why', () async {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(await _preferences()),
        ...testOverrides(services, secrets: secrets),
      ],
    );
    addTearDown(container.dispose);
    const track = TrackResult(
      extensionId: 'dev.test.music',
      id: 't1',
      title: 'Moon',
    );
    final song = await container.read(extensionServiceProvider).addTrack(track);
    final player = container.read(playerProvider.notifier);

    await player.playSong(song);
    expect(container.read(playerProvider).error, contains('No audio'));
    expect(backend.calls.where((c) => c.method == 'playerLoad'), isEmpty);

    backend.addExtension(
      FakeBackend.extensionInfo('dev.test.music', capabilities: ['audio']),
    );
    backend.audioSources.add({
      'kind': 'original',
      'url': 'https://cdn.example.org/1.mp3',
      'headers': {'Referer': 'https://example.org'},
    });
    await player.playSong(song);
    final load = argsOf('playerLoad');
    expect((load['sources']! as List).single, {
      'kind': 'original',
      'url': 'https://cdn.example.org/1.mp3',
      'headers': {'Referer': 'https://example.org'},
      'extensionId': 'dev.test.music',
      'cacheKey': ExtensionService.cacheKey('dev.test.music', 't1', 'original'),
    });
    expect(container.read(playerProvider).streaming, isTrue);
  });

  test('backups carry extensions and repositories but no secrets', () async {
    final package = File('${services.storage.root.path}/pkg.kalaoext')
      ..writeAsStringSync('package bytes');
    backend.addExtension({
      ...FakeBackend.extensionInfo('dev.test.a', settings: [_token, _region]),
      'packagePath': package.path,
      'settings': {'region': 'tw'},
    });
    backend.repositoryListings.add({
      'repository': {
        'url': 'https://repo.example.org/index.json',
        'name': 'Repo',
        'publicKey': 'ed25519:key',
      },
    });
    secrets.values[ExtensionService.secretKey('dev.test.a', 'token')] =
        'never-in-backups';
    final backups = BackupService(
      services,
      factory: databaseFactoryFfiNoIsolate,
      extensions: service,
    );
    final output = '${services.storage.root.path}/b.kalaobackup';
    await backups.create(outputPath: output, settings: const AppSettings());
    final archive = File(output).readAsStringSync();
    expect(archive, isNot(contains('never-in-backups')));
    final files = (jsonDecode(archive) as Map)['files'] as Map;
    expect(files.keys, contains('extensions/dev.test.a.kalaoext'));
    final state =
        jsonDecode(
              utf8.decode(base64Decode(files['extensions.json'] as String)),
            )
            as Map;
    expect(((state['extensions'] as List).single as Map)['settings'], {
      'region': 'tw',
    });

    // Restore on a "new device": installed from the backup's package.
    secrets.values.clear();
    backend.extensions.clear();
    backend.repositoryListings.clear();
    final staged = await backups.inspect(output);
    backend.packages[p.join(
      staged.dir.path,
      'extensions',
      'dev.test.a.kalaoext',
    )] = FakeBackend.extensionInfo(
      'dev.test.a',
      settings: [_token, _region],
    );
    await backups.restore(
      staged,
      RestoreMode.merge,
      current: const AppSettings(),
    );
    expect(backend.extensions.single['id'], 'dev.test.a');
    expect(backend.extensions.single['missingSecrets'], ['token']);
    expect(backend.repositoryListings, hasLength(1));
    expect(
      backend.calls.where(
        (c) =>
            c.method == 'setExtensionSetting' &&
            FakeBackend.argsOf(c)['value'] == 'tw',
      ),
      isNotEmpty,
    );
  });

  test('shared .kalaoext files go to the install prompt', () {
    expect(
      sharedFilesAction(['lrclib.kalaoext']),
      SharedFilesAction.installExtension,
    );
  });

  testWidgets('the install prompt shows hosts and fingerprint, then installs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    backend.packages['/tmp/lrclib.kalaoext'] = FakeBackend.extensionInfo(
      'app.kalao.lrclib',
      name: 'LRCLIB',
      hosts: ['lrclib.net'],
    );
    await _pump(
      tester,
      services,
      secrets,
      Consumer(
        builder: (context, ref, _) => Scaffold(
          body: FilledButton(
            onPressed: () =>
                installExtensionFile(context, ref, '/tmp/lrclib.kalaoext'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await _settle(tester);
    expect(find.text('Install LRCLIB?'), findsOneWidget);
    expect(find.text('lrclib.net'), findsOneWidget);
    expect(find.textContaining('abab abab'), findsOneWidget);
    expect(
      find.textContaining('Not from a repository you trust'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Install'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await _settle(tester);
    expect(backend.extensions.single['id'], 'app.kalao.lrclib');
    expect(find.text('LRCLIB installed'), findsOneWidget);
  });

  testWidgets('the Extensions tab lists, toggles and opens extensions', (
    tester,
  ) async {
    backend.addExtension(
      FakeBackend.extensionInfo(
        'dev.test.a',
        name: 'Lyrics Finder',
        settings: [_token, _region],
      ),
    );
    await _pump(tester, services, secrets, const ExtensionsTab());
    expect(find.text('Lyrics Finder'), findsOneWidget);
    expect(find.textContaining('Needs a setting'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await _settle(tester);
    expect(backend.extensions.single['enabled'], isFalse);
  });

  testWidgets('the settings form saves a secret to secure storage', (
    tester,
  ) async {
    backend.addExtension(
      FakeBackend.extensionInfo(
        'dev.test.a',
        name: 'Lyrics Finder',
        settings: [_token, _region],
      ),
    );
    await _pump(
      tester,
      services,
      secrets,
      const ExtensionDetailScreen(id: 'dev.test.a'),
    );
    expect(find.text('api.example.org'), findsOneWidget);
    await tester.tap(find.text('API token'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'my-secret');
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(
      secrets.values[ExtensionService.secretKey('dev.test.a', 'token')],
      'my-secret',
    );
    expect(find.text('Saved (hidden)'), findsOneWidget);
    expect(find.text('my-secret'), findsNothing);
  });
}

Future<SharedPreferences> _preferences() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

Future<void> _pump(
  WidgetTester tester,
  LibraryServices services,
  SecretStore secrets,
  Widget child,
) async {
  final preferences = (await tester.runAsync(_preferences))!;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(services, secrets: secrets),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
