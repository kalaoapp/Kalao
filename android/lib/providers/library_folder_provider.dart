import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/l10n/supported_locales.dart';
import 'package:kalao/models/library_folder.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/library_folder_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Folders');

/// The folder being scanned and how far it got.
typedef FolderScanState = ({int folderId, int done, int total});

/// Music folders (FEATURES 6.8) and the running scan, for the Library
/// folders screen.
@immutable
class LibraryFoldersState {
  const LibraryFoldersState({
    this.folders = const [],
    this.loaded = false,
    this.scan,
  });

  final List<LibraryFolder> folders;
  final bool loaded;
  final FolderScanState? scan;

  bool get scanning => scan != null;

  LibraryFoldersState copyWith({
    List<LibraryFolder>? folders,
    bool? loaded,
    FolderScanState? Function()? scan,
  }) => LibraryFoldersState(
    folders: folders ?? this.folders,
    loaded: loaded ?? this.loaded,
    scan: scan != null ? scan() : this.scan,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryFoldersState &&
      listEquals(other.folders, folders) &&
      other.loaded == loaded &&
      other.scan == scan;

  @override
  int get hashCode => Object.hash(Object.hashAll(folders), loaded, scan);
}

final libraryFoldersProvider =
    NotifierProvider<LibraryFoldersController, LibraryFoldersState>(
      LibraryFoldersController.new,
    );

/// Adds, removes and scans music folders, one scan at a time. Scans the
/// user starts run in the foreground work service; the scan on app start
/// does not (most find nothing new).
class LibraryFoldersController extends Notifier<LibraryFoldersState> {
  static const _workKind = 'folders';

  var _cancel = false;

  @override
  LibraryFoldersState build() {
    unawaited(_reload());
    return const LibraryFoldersState();
  }

  LibraryFolderService get _service =>
      ref.read(libraryServicesProvider).folders;

  AppLocalizations get _l10n => lookupAppLocalizations(
    appLocaleFor(ref.read(settingsProvider).localeTag),
  );

  Future<void> _reload() async {
    final folders = await _service.folders();
    if (!ref.mounted) return;
    state = state.copyWith(folders: folders, loaded: true);
  }

  /// Asks for a folder, adds it and scans it. Null when the user cancelled.
  /// Throws [FolderOverlapException] for a folder inside (or around) a
  /// music folder.
  Future<FolderScanResult?> pickAndAdd() async {
    final uri = await PlatformBridge.pickDocumentTree();
    if (uri == null) return null;
    final folder = await _service.addFolder(uri);
    await _reload();
    return scan(folder);
  }

  /// Removes [folder] and its songs; the files stay where they are.
  Future<int> remove(LibraryFolder folder) async {
    if (state.scan?.folderId == folder.id) cancel();
    final removed = await _service.removeFolder(folder);
    // The backup folder may be the same grant.
    if (ref.read(settingsProvider).backupFolderUri != folder.treeUri) {
      try {
        await PlatformBridge.releaseDocumentTree(folder.treeUri);
      } catch (error) {
        _log.w('Could not release ${folder.name}', error);
      }
    }
    ref.read(libraryRevisionProvider.notifier).bump();
    await _reload();
    return removed;
  }

  void cancel() => _cancel = true;

  /// Scans [folder]; null when another scan is running.
  Future<FolderScanResult?> scan(LibraryFolder folder) async =>
      (await _run([folder], foreground: true)).firstOrNull;

  /// Scans every folder; [foreground] when the user asked for it, [full]
  /// to read every file again (Force Full Scan).
  Future<List<FolderScanResult>> scanAll({
    bool foreground = false,
    bool full = false,
  }) async {
    final folders = await _service.folders();
    return _run(folders, foreground: foreground, full: full);
  }

  /// The scan on app start: the folders the auto-scan setting says are due
  /// ([FolderScanSchedule]); none when it is manual.
  Future<List<FolderScanResult>> scanDue({DateTime? now}) async {
    final interval = ref.read(settingsProvider).folderScanSchedule.interval;
    if (interval == null) return const [];
    final at = now ?? DateTime.now();
    final due = [
      for (final folder in await _service.folders())
        if (folder.scannedAt == null ||
            folder.error != null ||
            at.difference(folder.scannedAt!) >= interval)
          folder,
    ];
    return _run(due, foreground: false);
  }

  /// On resume: folders whose storage was offline, in case it is back.
  Future<List<FolderScanResult>> scanOffline() async {
    final offline = [
      for (final folder in await _service.folders())
        if (folder.isOffline) folder,
    ];
    return _run(offline, foreground: false);
  }

  /// Songs whose original is gone (FEATURES 6.9), and how many of them have
  /// lyrics, for the cleanup prompt.
  Future<({int songs, int withLyrics})> missing() async {
    final ids = await _service.missingSongs();
    final library = ref.read(libraryServicesProvider).library;
    return (songs: ids.length, withLyrics: await library.countWithLyrics(ids));
  }

  /// Deletes the songs whose original is gone (Cleanup Missing Files).
  Future<int> cleanupMissing() async {
    final removed = await _service.cleanupMissing();
    if (removed > 0) ref.read(libraryRevisionProvider.notifier).bump();
    await _reload();
    return removed;
  }

  Future<List<FolderScanResult>> _run(
    List<LibraryFolder> folders, {
    required bool foreground,
    bool full = false,
  }) async {
    if (state.scanning || folders.isEmpty) return const [];
    _cancel = false;
    state = state.copyWith(
      scan: () => (folderId: folders.first.id, done: 0, total: 0),
    );
    if (foreground) {
      await _work(
        () => PlatformBridge.startBackgroundWork(
          kind: _workKind,
          title: _l10n.foldersScanning,
        ),
      );
    }
    final results = <FolderScanResult>[];
    try {
      for (final folder in folders) {
        if (_cancel) break;
        state = state.copyWith(
          scan: () => (folderId: folder.id, done: 0, total: 0),
        );
        try {
          final result = await _service.scan(
            folder,
            cancelled: () => _cancel,
            full: full,
            onProgress: (done, total) =>
                _progress(folder, done, total, foreground),
          );
          results.add(result);
          if (result.changed) ref.read(libraryRevisionProvider.notifier).bump();
        } catch (error, stack) {
          _log.e('Scan of ${folder.name} failed', error, stack);
        }
      }
    } finally {
      if (foreground) {
        await _work(() => PlatformBridge.stopBackgroundWork(_workKind));
      }
      if (ref.mounted) {
        state = state.copyWith(scan: () => null);
        await _reload();
      }
    }
    return results;
  }

  void _progress(LibraryFolder folder, int done, int total, bool foreground) {
    if (!ref.mounted) return;
    state = state.copyWith(
      scan: () => (folderId: folder.id, done: done, total: total),
    );
    if (foreground && total > 0 && (done % 10 == 0 || done == total)) {
      unawaited(
        _work(
          () => PlatformBridge.updateBackgroundWork(
            kind: _workKind,
            title: _l10n.foldersScanning,
            text: folder.name,
            progress: done * 100 ~/ total,
          ),
        ),
      );
    }
  }

  /// The scan runs without the service if Android refuses it (or in tests).
  Future<void> _work(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (error) {
      _log.w('Background work service unavailable', error);
    }
  }
}

/// The files the scans of [LibraryFolder.id] could not add.
final skippedFolderFilesProvider =
    FutureProvider.family<List<SkippedFolderFile>, int>((ref, folderId) async {
      ref.watch(libraryFoldersProvider.select((s) => s.folders));
      final service = ref.watch(libraryServicesProvider).folders;
      return service.store.skipped(folderId);
    });
