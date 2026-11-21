import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/library_folder.dart';
import 'package:kalao/providers/library_folder_provider.dart';
import 'package:kalao/services/library_folder_service.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Music folders (FEATURES 6.8): add, scan and remove folders whose songs
/// play in place.
class LibraryFoldersScreen extends ConsumerWidget {
  const LibraryFoldersScreen({super.key});

  static void _show(BuildContext context, String message) =>
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

  static void _report(BuildContext context, FolderScanResult? result) {
    if (result == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    _show(
      context,
      result.lostAccess
          ? l10n.foldersAccessLost
          : l10n.foldersScanResult(
              result.added.length,
              result.updated,
              result.removed,
            ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    try {
      final result = await ref
          .read(libraryFoldersProvider.notifier)
          .pickAndAdd();
      if (context.mounted) _report(context, result);
    } on FolderOverlapException catch (error) {
      if (context.mounted) _show(context, l10n.foldersOverlap(error.other));
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    LibraryFolder folder,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.foldersRemove),
        content: Text(l10n.foldersRemoveConfirm(folder.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.foldersRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(libraryFoldersProvider.notifier).remove(folder);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(libraryFoldersProvider);
    final controller = ref.read(libraryFoldersProvider.notifier);
    final scan = state.scan;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.foldersTitle),
        actions: [
          IconButton(
            tooltip: l10n.foldersScanAll,
            icon: const Icon(Icons.refresh),
            onPressed: state.scanning || state.folders.isEmpty
                ? null
                : () async {
                    final results = await controller.scanAll(foreground: true);
                    if (!context.mounted || results.isEmpty) return;
                    _report(
                      context,
                      FolderScanResult(
                        added: [for (final r in results) ...r.added],
                        updated: results.fold(0, (n, r) => n + r.updated),
                        removed: results.fold(0, (n, r) => n + r.removed),
                      ),
                    );
                  },
          ),
        ],
        bottom: scan == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: scan.total == 0 ? null : scan.done / scan.total,
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-folder',
        onPressed: state.scanning ? null : () => _add(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(l10n.foldersAdd),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Text(
              l10n.foldersIntro,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final folder in state.folders)
            _FolderTile(
              folder: folder,
              scan: scan?.folderId == folder.id ? scan : null,
              busy: state.scanning,
              onScan: () async {
                final result = await controller.scan(folder);
                if (context.mounted) _report(context, result);
              },
              onCancel: controller.cancel,
              onRemove: () => _remove(context, ref, folder),
            ),
        ],
      ),
    );
  }
}

enum _FolderAction { scan, skipped, remove }

class _FolderTile extends ConsumerWidget {
  const _FolderTile({
    required this.folder,
    required this.scan,
    required this.busy,
    required this.onScan,
    required this.onCancel,
    required this.onRemove,
  });

  final LibraryFolder folder;
  final FolderScanState? scan;
  final bool busy;
  final VoidCallback onScan;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final scannedAt = folder.scannedAt;
    final lines = [
      [
        l10n.foldersSongs(folder.songs),
        if (scannedAt == null)
          l10n.foldersNotScanned
        else
          l10n.foldersScannedAt(
            DateFormat.yMMMd(
              Localizations.localeOf(context).toLanguageTag(),
            ).add_Hm().format(scannedAt),
          ),
      ].join(' · '),
      if (scan case final scan? when scan.total > 0)
        l10n.foldersProgress(scan.done, scan.total),
      if (folder.accessLost) l10n.foldersAccessLost,
      if (folder.skipped > 0) l10n.foldersSkipped(folder.skipped),
    ];
    return ListTile(
      leading: Icon(
        folder.accessLost ? Icons.folder_off_outlined : Icons.folder_outlined,
        color: folder.accessLost ? colors.error : null,
      ),
      title: Text(folder.name),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 1,
      trailing: scan != null
          ? IconButton(
              tooltip: l10n.actionCancel,
              icon: const Icon(Icons.close),
              onPressed: onCancel,
            )
          : PopupMenuButton<_FolderAction>(
              onSelected: (action) => switch (action) {
                _FolderAction.scan => onScan(),
                _FolderAction.skipped => _showSkipped(context),
                _FolderAction.remove => onRemove(),
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _FolderAction.scan,
                  enabled: !busy,
                  child: Text(l10n.foldersScan),
                ),
                if (folder.skipped > 0)
                  PopupMenuItem(
                    value: _FolderAction.skipped,
                    child: Text(l10n.foldersSkippedTitle),
                  ),
                PopupMenuItem(
                  value: _FolderAction.remove,
                  child: Text(l10n.foldersRemove),
                ),
              ],
            ),
    );
  }

  Future<void> _showSkipped(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _SkippedSheet(folder: folder),
  );
}

class _SkippedSheet extends ConsumerWidget {
  const _SkippedSheet({required this.folder});

  final LibraryFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final files =
        ref.watch(skippedFolderFilesProvider(folder.id)).asData?.value ??
        const [];
    return DraggableScrollableSheet(
      expand: false,
      builder: (context, controller) => ListView(
        controller: controller,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.space16),
            child: Text(
              l10n.foldersSkippedTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final file in files)
            ListTile(
              title: Text(file.name),
              subtitle: Text(
                [
                  if (file.dir.isNotEmpty) file.dir,
                  file.reason == 'format'
                      ? l10n.foldersSkipFormat
                      : l10n.foldersSkipUnreadable,
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }
}
