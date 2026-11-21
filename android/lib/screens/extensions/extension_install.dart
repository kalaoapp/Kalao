import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/extension_widgets.dart';

/// Picks a `.kalaoext` and runs the install prompt.
Future<void> pickAndInstallExtension(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context);
  final picked = await FilePicker.pickFiles(dialogTitle: l10n.extensionPick);
  final path = picked.firstOrNull?.path;
  if (path == null || !context.mounted) return;
  try {
    await installExtensionFile(context, ref, path);
  } finally {
    await FilePicker.clearTemporaryFiles();
  }
}

/// Shows what the package at [path] is and asks before installing it
/// (EXTENSIONS.md §7: name, author, capabilities, hosts, fingerprint).
Future<void> installExtensionFile(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final ExtensionPackagePreview preview;
  try {
    preview = await ref.read(extensionServiceProvider).inspect(path);
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.extensionInvalid('$error'))),
    );
    return;
  }
  if (!context.mounted) return;
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ExtensionInstallPrompt(preview: preview),
  );
  if (confirmed != true) return;
  try {
    final info = await ref
        .read(extensionsProvider.notifier)
        .installFile(path, allowDowngrade: preview.isDowngrade);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.extensionInstalled(info.manifest.name))),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.extensionInstallFailed('$error'))),
    );
  }
}

class ExtensionInstallPrompt extends StatelessWidget {
  const ExtensionInstallPrompt({super.key, required this.preview});

  final ExtensionPackagePreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final manifest = preview.manifest;
    final verified = preview.verifiedBy;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space24,
          0,
          AppTokens.space24,
          AppTokens.space24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preview.isUpdate
                  ? l10n.extensionUpdateTitle(manifest.name)
                  : l10n.extensionInstallTitle(manifest.name),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppTokens.space4),
            Text(
              [
                l10n.extensionVersion(manifest.version),
                if (manifest.author.isNotEmpty) manifest.author,
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            if (manifest.description.isNotEmpty) ...[
              const SizedBox(height: AppTokens.space8),
              Text(manifest.description),
            ],
            if (preview.installedVersion case final installed?) ...[
              const SizedBox(height: AppTokens.space8),
              Text(
                preview.isDowngrade
                    ? l10n.extensionDowngrade(installed)
                    : l10n.extensionInstalledVersion(installed),
                style: preview.isDowngrade
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ],
            const SizedBox(height: AppTokens.space16),
            CapabilityChips(capabilities: manifest.capabilities),
            const SizedBox(height: AppTokens.space16),
            HostList(manifest: manifest),
            const SizedBox(height: AppTokens.space16),
            Text(l10n.extensionFingerprint, style: theme.textTheme.titleSmall),
            SelectableText(
              preview.fingerprint,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: AppTokens.space8),
            Row(
              children: [
                Icon(
                  verified != null
                      ? Icons.verified_outlined
                      : Icons.warning_amber_outlined,
                  size: 20,
                  color: verified != null
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: AppTokens.space8),
                Expanded(
                  child: Text(
                    verified != null
                        ? l10n.extensionVerifiedBy(verified)
                        : l10n.extensionUnverified,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.space8),
            Text(
              l10n.extensionResponsibility,
              style: theme.textTheme.bodySmall,
            ),
            if (!preview.supported) ...[
              const SizedBox(height: AppTokens.space8),
              Text(
                l10n.extensionNeedsNewer(manifest.minKalao ?? ''),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: AppTokens.space24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.actionCancel),
                ),
                const SizedBox(width: AppTokens.space8),
                FilledButton(
                  onPressed: preview.supported
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: Text(
                    preview.isUpdate
                        ? l10n.extensionUpdate
                        : l10n.extensionInstall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
