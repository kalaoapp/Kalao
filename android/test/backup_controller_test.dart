import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/app.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/backup_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/settings/backup_screen.dart';
import 'package:kalao/services/backup_runs.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

/// Backups through the controller: saving to a picked document, the
/// scheduled backup (due check, pruning, failures) and the Backup screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late LibraryServices services;
  const folder = 'content://tree/primary%3ABackups';

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
    await services.library.insertSong(
      const NewSong(
        title: 'Moon',
        media: [
          NewMediaFile(kind: MediaKind.original, path: '/m.mp3', sha256: 's'),
        ],
      ),
    );
  });
  tearDown(() async {
    backend.uninstall();
    await closeTestServices(services);
  });

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    ...testOverrides(services),
    backupServiceProvider.overrideWith(
      (ref) => BackupService(
        ref.watch(libraryServicesProvider),
        factory: databaseFactoryFfiNoIsolate,
      ),
    ),
  ];

  Future<ProviderContainer> container() async {
    final container = ProviderContainer(overrides: await overrides());
    addTearDown(container.dispose);
    return container;
  }

  List<String> folderFiles() => [
    for (final uri in backend.documents.keys)
      if (uri.startsWith('$folder/document/')) uri.split('/').last,
  ]..sort();

  test('saving copies a backup to the picked document', () async {
    final c = await container();
    final bytes = await c
        .read(backupControllerProvider.notifier)
        .saveTo('content://docs/picked', includeMedia: false);
    expect(bytes, greaterThan(0));
    expect(backend.documents['content://docs/picked']!.existsSync(), isTrue);
    expect(services.storage.backupWork.listSync(), isEmpty);
    final run = await BackupRuns(services.library.db).latest(target: 'file');
    expect(run!.status, 'ok');
    expect(
      backend.calls.map((c) => c.method),
      containsAllInOrder(['startBackgroundWork', 'stopBackgroundWork']),
    );
  });

  test('a scheduled backup runs when due and keeps the newest N', () async {
    final c = await container();
    final settings = c.read(settingsProvider.notifier);
    final controller = c.read(backupControllerProvider.notifier);
    final day = DateTime(2026, 11, 17, 9);
    expect(await controller.runScheduledIfDue(now: day), isFalse); // off

    await settings.setBackupFolderUri(folder);
    await settings.setBackupSchedule(BackupSchedule.daily);
    await settings.setBackupKeep(2);
    // Someone else's file in the same folder is never touched.
    backend.documents['$folder/document/notes.txt'] = File(
      '${services.storage.root.path}/notes.txt',
    )..writeAsStringSync('mine');

    expect(await controller.runScheduledIfDue(now: day), isTrue);
    expect(
      await controller.runScheduledIfDue(
        now: day.add(const Duration(hours: 5)),
      ),
      isFalse,
    );
    for (var i = 1; i <= 3; i++) {
      expect(
        await controller.runScheduledIfDue(now: day.add(Duration(days: i))),
        isTrue,
      );
    }
    expect(folderFiles(), [
      'kalao-2026-11-19-0900.kalaobackup',
      'kalao-2026-11-20-0900.kalaobackup',
      'notes.txt',
    ]);
    final last = await c.read(lastScheduledBackupProvider.future);
    expect(last!.status, 'ok');
    expect(last.bytes, greaterThan(0));
  });

  test('a failing folder is logged and retried an hour later', () async {
    final c = await container();
    final settings = c.read(settingsProvider.notifier);
    final controller = c.read(backupControllerProvider.notifier);
    await settings.setBackupFolderUri(folder);
    await settings.setBackupSchedule(BackupSchedule.weekly);
    backend.failing['writeFileToTree'] = 'access revoked';
    final now = DateTime(2026, 11, 17, 9);
    expect(await controller.runScheduledIfDue(now: now), isFalse);
    final failed = await BackupRuns(services.library.db).latest();
    expect(failed!.status, 'failed');
    expect(failed.error, contains('access revoked'));
    backend.failing.clear();
    expect(
      await controller.runScheduledIfDue(
        now: now.add(const Duration(minutes: 10)),
      ),
      isFalse,
    );
    expect(
      await controller.runScheduledIfDue(
        now: now.add(const Duration(hours: 2)),
      ),
      isTrue,
    );
  });

  testWidgets('the backup screen saves, previews and merges a backup', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(overrides: await overrides(), child: const KalaoApp()),
    );
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(MaterialApp).first);
    final c = ProviderScope.containerOf(element);
    c.read(routerProvider).push('/settings/backup');
    await tester.pumpAndSettle();
    expect(find.text('Backup and restore'), findsOneWidget);
    expect(find.textContaining('not encrypted'), findsOneWidget);

    /// Lets the real file and database work finish.
    Future<void> settle() async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (!c.read(backupControllerProvider) && i > 5) break;
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Save a backup…'));
    await settle();
    expect(find.text('Backup saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // let the snackbar go
    await tester.pumpAndSettle();

    // The preview sheet for the saved file; Merge is the default.
    final saved = backend.documents['content://docs/picked']!;
    final staged = (await tester.runAsync(
      () => c.read(backupControllerProvider.notifier).inspect(saved.path),
    ))!;
    unawaited(
      confirmRestore(tester.element(find.byType(BackupScreen)), staged),
    );
    await tester.pumpAndSettle();
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(find.text('1 (0 new)'), findsOneWidget);
    final apply = find.widgetWithText(FilledButton, 'Restore');
    await tester.ensureVisible(apply);
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await settle();
    expect(find.text('Backup restored'), findsOneWidget);
    expect(await tester.runAsync(() => services.library.songs()), hasLength(1));
  });
}
