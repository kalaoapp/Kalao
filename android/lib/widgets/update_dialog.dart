// Mornye's update_dialog.dart, sized for Kalao.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/services/external_links.dart';
import 'package:kalao/services/update_service.dart';

Future<void> showUpdateDialog(BuildContext context, AppRelease release) =>
    showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(release: release),
    );

/// The new version and its changelog. "Open release page" is always there;
/// nothing is downloaded until the user taps Update.
class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final downloading = state is UpdateDownloading;
    return AlertDialog(
      title: Text(l10n.updateTitle(release.version)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.updateCurrent(AppInfo.version)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  release.notes.trim().isEmpty
                      ? l10n.updateNoNotes
                      : release.notes.trim(),
                ),
              ),
            ),
            if (state case UpdateDownloading(:final progress)) ...[
              const SizedBox(height: 16),
              Text(l10n.updateDownloading),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
            ],
            if (state case UpdateFailed(:final message)) ...[
              const SizedBox(height: 16),
              Text(
                l10n.updateFailed(message),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => openExternalUrl(release.page),
          child: Text(l10n.updateOpenPage),
        ),
        TextButton(
          onPressed: downloading
              ? null
              : () {
                  controller.dismiss();
                  Navigator.pop(context);
                },
          child: Text(l10n.updateLater),
        ),
        FilledButton(
          onPressed: downloading ? null : () => controller.install(release),
          child: Text(l10n.updateInstall),
        ),
      ],
    );
  }
}
