import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/providers/backup_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/backup_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/services/poc_import_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/settings_group.dart';
import 'package:kalao/widgets/stepper_tile.dart';

/// Backup and restore (FEATURES 7.1–7.4).
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _includeMedia = false;

  BackupController get _controller =>
      ref.read(backupControllerProvider.notifier);

  void _show(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final uri = await PlatformBridge.createDocument(
      BackupService.fileName(DateTime.now()),
    );
    if (uri == null) return;
    try {
      await _controller.saveTo(uri, includeMedia: _includeMedia);
      _show(l10n.backupSaved);
    } catch (error) {
      _show(l10n.backupFailed('$error'));
    }
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context);
    final picked = await FilePicker.pickFiles(dialogTitle: l10n.restorePick);
    final path = picked.firstOrNull?.path;
    if (path == null || !mounted) return;
    final StagedBackup staged;
    try {
      staged = await restoreBackupFile(context, path);
    } catch (error) {
      _show(l10n.restoreFailed('$error'));
      return;
    }
    if (mounted) await confirmRestore(context, staged);
    // The picker's cached copy is no longer needed.
    await FilePicker.clearTemporaryFiles();
  }

  /// Lyrics, favorites and plays from the old web POC's export.
  Future<void> _importPoc() async {
    final l10n = AppLocalizations.of(context);
    final picked = await FilePicker.pickFiles(dialogTitle: l10n.pocImport);
    if (picked.isEmpty || !mounted) return;
    try {
      final text = utf8.decode(
        await picked.first.readAsBytes(),
        allowMalformed: true,
      );
      final services = ref.read(libraryServicesProvider);
      final result = await PocImportService(services).importJson(text);
      ref.read(libraryRevisionProvider.notifier).bump();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.pocImportDone),
          content: SingleChildScrollView(
            child: Text(
              [
                l10n.pocImportSummary(
                  result.matched,
                  result.lyrics,
                  result.favorites,
                  result.plays,
                ),
                if (result.unmatched.isNotEmpty) ...[
                  '',
                  l10n.pocImportUnmatched(result.unmatched.length),
                  ...result.unmatched,
                ],
              ].join('\n'),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.actionOk),
            ),
          ],
        ),
      );
    } catch (error) {
      _show(l10n.restoreFailed('$error'));
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final busy = ref.watch(backupControllerProvider);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final last = ref.watch(lastScheduledBackupProvider).asData?.value;
    final folder = settings.backupFolderUri;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.backupTitle),
        bottom: busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTokens.space24),
        children: [
          SettingsGroup(
            title: l10n.backupNow,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.audio_file_outlined),
                title: Text(l10n.backupIncludeMedia),
                subtitle: Text(l10n.backupIncludeMediaSubtitle),
                value: _includeMedia,
                onChanged: (value) => setState(() => _includeMedia = value),
              ),
              ListTile(
                leading: const Icon(Icons.save_alt),
                title: Text(l10n.backupSave),
                subtitle: Text(l10n.backupUnencrypted),
                enabled: !busy,
                onTap: _save,
              ),
            ],
          ),
          SettingsGroup(
            title: l10n.restoreTitle,
            children: [
              ListTile(
                leading: const Icon(Icons.settings_backup_restore),
                title: Text(l10n.restoreFromFile),
                subtitle: Text(l10n.restoreSubtitle),
                enabled: !busy,
                onTap: _restore,
              ),
              ListTile(
                leading: const Icon(Icons.move_down),
                title: Text(l10n.pocImport),
                subtitle: Text(l10n.pocImportSubtitle),
                enabled: !busy,
                onTap: _importPoc,
              ),
            ],
          ),
          SettingsGroup(
            title: l10n.backupScheduled,
            children: [
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(l10n.backupFolder),
                subtitle: Text(
                  folder == null ? l10n.backupFolderNone : folderLabel(folder),
                ),
                onTap: () async {
                  final uri = await PlatformBridge.pickDocumentTree();
                  if (uri != null) await notifier.setBackupFolderUri(uri);
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(l10n.backupSchedule),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: AppTokens.space8),
                  child: SegmentedButton<BackupSchedule>(
                    segments: [
                      ButtonSegment(
                        value: BackupSchedule.off,
                        label: Text(l10n.backupScheduleOff),
                      ),
                      ButtonSegment(
                        value: BackupSchedule.daily,
                        label: Text(l10n.backupScheduleDaily),
                      ),
                      ButtonSegment(
                        value: BackupSchedule.weekly,
                        label: Text(l10n.backupScheduleWeekly),
                      ),
                    ],
                    selected: {settings.backupSchedule},
                    onSelectionChanged: folder == null
                        ? null
                        : (value) async {
                            await notifier.setBackupSchedule(value.first);
                            unawaited(_controller.runScheduledIfDue());
                          },
                  ),
                ),
              ),
              StepperTile(
                icon: Icons.layers_outlined,
                title: l10n.backupKeep,
                value: '${settings.backupKeep}',
                decreaseTooltip: l10n.backupKeepFewer,
                increaseTooltip: l10n.backupKeepMore,
                onDecrease: settings.backupKeep > 1
                    ? () => notifier.setBackupKeep(settings.backupKeep - 1)
                    : null,
                onIncrease: settings.backupKeep < 30
                    ? () => notifier.setBackupKeep(settings.backupKeep + 1)
                    : null,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.audio_file_outlined),
                title: Text(l10n.backupIncludeMedia),
                value: settings.backupIncludeMedia,
                onChanged: notifier.setBackupIncludeMedia,
              ),
              ListTile(
                leading: Icon(
                  last?.status == 'failed'
                      ? Icons.error_outline
                      : Icons.history,
                ),
                title: Text(l10n.backupLast),
                subtitle: Text(_lastRun(l10n, last)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _lastRun(AppLocalizations l10n, BackupRun? run) {
    if (run == null) return l10n.backupLastNever;
    final when = DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(run.startedAt);
    return switch (run.status) {
      'ok' => l10n.backupLastOk(when, formatBytes(run.bytes)),
      'running' => l10n.backupRunning,
      _ => l10n.backupLastFailed(when, run.error ?? ''),
    };
  }
}

/// The readable end of a SAF tree URI (`primary:Backups/Kalao` →
/// `Backups/Kalao`).
String folderLabel(String treeUri) {
  final id = Uri.decodeComponent(treeUri.split('/').last);
  final colon = id.indexOf(':');
  final path = colon < 0 ? id : id.substring(colon + 1);
  return path.isEmpty ? id : path;
}

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).round()} KB';
  return '$bytes B';
}

/// Checks a backup file (from the picker or a share) with a progress dialog.
Future<StagedBackup> restoreBackupFile(
  BuildContext context,
  String path,
) async {
  final l10n = AppLocalizations.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final navigator = Navigator.of(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: AppTokens.space16),
              Expanded(child: Text(l10n.restoreChecking)),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    return await container
        .read(backupControllerProvider.notifier)
        .inspect(path);
  } finally {
    navigator.pop();
  }
}

/// The preview (FEATURES 7.3) and the Merge / Replace choice.
Future<void> confirmRestore(BuildContext context, StagedBackup staged) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = container.read(backupControllerProvider.notifier);
  final mode = await showModalBottomSheet<RestoreMode>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => RestorePreviewSheet(preview: staged.preview),
  );
  if (mode == null) {
    await container.read(backupServiceProvider).discard(staged);
    return;
  }
  try {
    await controller.restore(staged, mode);
    messenger.showSnackBar(SnackBar(content: Text(l10n.restoreDone)));
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.restoreFailed('$error'))),
    );
  }
}

class RestorePreviewSheet extends StatefulWidget {
  const RestorePreviewSheet({super.key, required this.preview});

  final BackupPreview preview;

  @override
  State<RestorePreviewSheet> createState() => _RestorePreviewSheetState();
}

class _RestorePreviewSheetState extends State<RestorePreviewSheet> {
  RestoreMode _mode = RestoreMode.merge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = widget.preview;
    final created = preview.createdAt;
    final rows = [
      (
        Icons.event,
        l10n.restoreCreated,
        created == null
            ? '—'
            : DateFormat.yMMMd(
                Localizations.localeOf(context).toLanguageTag(),
              ).add_Hm().format(created),
      ),
      (
        Icons.music_note_outlined,
        l10n.restoreSongs,
        l10n.restoreSongsValue(preview.songs, preview.newSongs),
      ),
      (Icons.lyrics_outlined, l10n.restoreLyrics, '${preview.withLyrics}'),
      (Icons.favorite_border, l10n.restoreFavorites, '${preview.favorites}'),
      (Icons.history, l10n.restorePlays, '${preview.plays}'),
      (
        Icons.audio_file_outlined,
        l10n.restoreMedia,
        preview.mediaFiles == 0
            ? l10n.restoreMediaNone
            : '${preview.mediaFiles}',
      ),
      (Icons.sd_storage_outlined, l10n.restoreSize, formatBytes(preview.bytes)),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space16,
          0,
          AppTokens.space16,
          AppTokens.space16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.restorePreviewTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppTokens.space8),
            for (final (icon, label, value) in rows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon),
                title: Text(label),
                trailing: Text(value),
              ),
            const SizedBox(height: AppTokens.space8),
            RadioGroup<RestoreMode>(
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value ?? _mode),
              child: Column(
                children: [
                  RadioListTile(
                    value: RestoreMode.merge,
                    title: Text(l10n.restoreMerge),
                    subtitle: Text(l10n.restoreMergeSubtitle),
                  ),
                  RadioListTile(
                    value: RestoreMode.replace,
                    title: Text(l10n.restoreReplace),
                    subtitle: Text(l10n.restoreReplaceSubtitle),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.space16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.actionCancel),
                ),
                const SizedBox(width: AppTokens.space8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _mode),
                  child: Text(l10n.restoreApply),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
