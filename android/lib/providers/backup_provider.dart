import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/l10n/supported_locales.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/backup_runs.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('Backup');

/// Replaced in tests with one on the FFI database factory.
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(libraryServicesProvider)),
);

/// The newest scheduled backup run, for the Backup screen.
final lastScheduledBackupProvider = FutureProvider<BackupRun?>((ref) {
  ref.watch(backupControllerProvider);
  return BackupRuns(
    ref.watch(libraryServicesProvider).library.db,
  ).latest(target: 'folder');
});

final backupControllerProvider = NotifierProvider<BackupController, bool>(
  BackupController.new,
);

/// Runs one backup or restore at a time (state: whether one is running),
/// inside the foreground work service so it survives the screen turning off.
class BackupController extends Notifier<bool> {
  static const _workKind = 'backup';

  @override
  bool build() => false;

  BackupService get _service => ref.read(backupServiceProvider);
  BackupRuns get _runs =>
      BackupRuns(ref.read(libraryServicesProvider).library.db);

  AppLocalizations get _l10n => lookupAppLocalizations(
    appLocaleFor(ref.read(settingsProvider).localeTag),
  );

  Future<T> _exclusive<T>(String title, Future<T> Function() body) async {
    if (state) throw BackupException(_l10n.backupBusy);
    state = true;
    try {
      await _foreground(
        () => PlatformBridge.startBackgroundWork(kind: _workKind, title: title),
      );
      return await body();
    } finally {
      await _foreground(() => PlatformBridge.stopBackgroundWork(_workKind));
      state = false;
    }
  }

  /// The work runs without the service if Android refuses it (or in tests).
  Future<void> _foreground(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (error) {
      _log.w('Background work service unavailable', error);
    }
  }

  Future<File> _tempArchive() async {
    final dir = ref.read(libraryServicesProvider).storage.backupWork;
    await dir.create(recursive: true);
    return File(
      p.join(
        dir.path,
        'out-${DateTime.now().microsecondsSinceEpoch}.kalaobackup',
      ),
    );
  }

  /// Writes a backup and copies it to the document [uri] the user picked.
  Future<int> saveTo(String uri, {required bool includeMedia}) =>
      _exclusive(_l10n.backupRunning, () async {
        final runs = _runs;
        final id = await runs.start('file');
        final file = await _tempArchive();
        try {
          final bytes = await _service.create(
            outputPath: file.path,
            settings: ref.read(settingsProvider),
            includeMedia: includeMedia,
          );
          await PlatformBridge.copyFileToDocument(file.path, uri);
          await runs.finish(id, bytes: bytes);
          return bytes;
        } catch (error) {
          await runs.finish(id, error: '$error');
          rethrow;
        } finally {
          if (file.existsSync()) await file.delete();
        }
      });

  Future<StagedBackup> inspect(String path) =>
      _exclusive(_l10n.restoreChecking, () => _service.inspect(path));

  /// Applies [staged]. Playback stops first: Replace swaps the databases
  /// under the player and the queue.
  Future<void> restore(StagedBackup staged, RestoreMode mode) =>
      _exclusive(_l10n.restoreRunning, () async {
        await ref.read(playerProvider.notifier).stop();
        final result = await _service.restore(
          staged,
          mode,
          current: ref.read(settingsProvider),
        );
        if (result.settings case final settings?) {
          await ref.read(settingsProvider.notifier).restore(settings);
        }
        final services = ref.read(libraryServicesProvider);
        if (result.addedSongs.isNotEmpty) {
          await services.importer.refreshSearchKeys(result.addedSongs);
        }
        // Lists, the queue and Home all follow the revision.
        ref.read(libraryRevisionProvider.notifier).bump();
      });

  /// Runs the scheduled backup when one is due (FEATURES 7.4, ADR-016):
  /// on app start and resume. Returns whether one ran successfully.
  Future<bool> runScheduledIfDue({DateTime? now}) async {
    final settings = ref.read(settingsProvider);
    final interval = settings.backupSchedule.interval;
    final folder = settings.backupFolderUri;
    if (interval == null || folder == null || state) return false;
    final at = now ?? DateTime.now();
    final runs = _runs;
    await runs.markInterrupted();
    final success = await runs.latest(target: 'folder', status: 'ok');
    if (success != null && at.difference(success.startedAt) < interval) {
      return false;
    }
    // A failing folder (access revoked, card removed) is retried hourly,
    // not on every resume.
    final attempt = await runs.latest(target: 'folder');
    if (attempt != null &&
        attempt.status == 'failed' &&
        at.difference(attempt.startedAt) < const Duration(hours: 1)) {
      return false;
    }
    try {
      await _exclusive(_l10n.backupRunning, () async {
        final id = await runs.start('folder', now: at);
        final file = await _tempArchive();
        try {
          final bytes = await _service.create(
            outputPath: file.path,
            settings: settings,
            includeMedia: settings.backupIncludeMedia,
          );
          await PlatformBridge.writeFileToTree(
            treeUri: folder,
            name: BackupService.fileName(at),
            path: file.path,
          );
          await _prune(folder, settings);
          await runs.finish(id, bytes: bytes);
        } catch (error) {
          await runs.finish(id, error: '$error');
          rethrow;
        } finally {
          if (file.existsSync()) await file.delete();
        }
      });
      return true;
    } catch (error) {
      _log.w('Scheduled backup failed', error);
      return false;
    }
  }

  /// Keeps the newest [AppSettings.backupKeep] Kalao backups in the folder;
  /// other files are never touched.
  Future<void> _prune(String folder, AppSettings settings) async {
    final backups =
        (await PlatformBridge.listDocumentTree(folder))
            .where((f) => BackupService.fileNamePattern.hasMatch(f.name))
            .toList()
          ..sort((a, b) => b.name.compareTo(a.name));
    for (final old in backups.skip(settings.backupKeep)) {
      await PlatformBridge.deleteDocument(old.uri);
    }
  }
}
