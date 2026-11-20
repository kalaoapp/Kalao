import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/app.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_import_sheet.dart';
import 'package:kalao/screens/shared_files.dart';
import 'package:kalao/services/library_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// Files opened with or shared to Kalao.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared files are routed by extension', () {
    expect(
      sharedFilesAction(['song.mp3', 'song.lrc']),
      SharedFilesAction.importAudio,
    );
    expect(
      sharedFilesAction(['kalao-2026.kalaobackup']),
      SharedFilesAction.restore,
    );
    expect(sharedFilesAction(['words.LRC']), SharedFilesAction.importLyrics);
    expect(sharedFilesAction(['photo.jpg']), SharedFilesAction.unsupported);
  });

  testWidgets('a shared .lrc opens the lyrics sheet for a chosen song', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': '0.1.0',
      }),
    });
    final backend = FakeBackend()..install();
    final services = (await tester.runAsync(openTestServices))!;
    addTearDown(() async {
      backend.uninstall();
      await tester.runAsync(() => closeTestServices(services));
    });
    final lrc = File('${services.storage.root.path}/shared-words.lrc')
      ..writeAsStringSync('[00:01.00]hello');
    await tester.runAsync(
      () => services.library.insertSong(
        const NewSong(
          title: 'Moon',
          media: [
            NewMediaFile(kind: MediaKind.original, path: '/m', sha256: 's'),
          ],
        ),
      ),
    );
    backend.shared.add({'path': lrc.path, 'name': 'words.lrc'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          ...testOverrides(services),
        ],
        child: const KalaoApp(),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Add these lyrics to'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Moon'),
      ),
    );
    await tester.pumpAndSettle();
    final sheet = tester.widget<LyricsImportSheet>(
      find.byType(LyricsImportSheet),
    );
    expect(sheet.song.title, 'Moon');
    expect(sheet.initialText, '[00:01.00]hello');
    expect(find.text('[00:01.00]hello'), findsOneWidget);
    expect(
      backend.calls.where((c) => c.method == 'takeSharedFiles'),
      isNotEmpty,
    );
    // The cache copy goes once the sheet closes.
    Navigator.of(tester.element(find.byType(LyricsImportSheet))).pop();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(lrc.existsSync(), isFalse);
  });
}
