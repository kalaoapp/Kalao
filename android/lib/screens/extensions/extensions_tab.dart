import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/extensions/extension_install.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/extension_widgets.dart';
import 'package:kalao/widgets/settings_group.dart';

/// The Extensions tab (FEATURES 5.x): installed extensions, install from a
/// file, repositories, provider order and developer mode.
class ExtensionsTab extends ConsumerWidget {
  const ExtensionsTab({super.key});

  Future<void> _loadFolder(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: l10n.extensionLoadFolder,
    );
    if (path == null) return;
    try {
      final info = await ref
          .read(extensionsProvider.notifier)
          .installFolder(path);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.extensionInstalled(info.manifest.name))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.extensionInstallFailed('$error'))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(extensionsProvider);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(extensionsProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navExtensions),
        actions: [
          IconButton(
            tooltip: l10n.extensionRepositories,
            icon: Badge(
              isLabelVisible: state.updates > 0,
              label: Text('${state.updates}'),
              child: const Icon(Icons.storefront_outlined),
            ),
            onPressed: () => context.push('/extensions/repositories'),
          ),
          IconButton(
            tooltip: l10n.extensionPriority,
            icon: const Icon(Icons.low_priority),
            onPressed: () => context.push('/extensions/priority'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'install-extension',
        onPressed: () => pickAndInstallExtension(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.extensionInstallFromFile),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await notifier.refresh();
          await notifier.refreshRepositories();
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (state.error case final error?)
              Padding(
                padding: const EdgeInsets.all(AppTokens.space16),
                child: Text(
                  l10n.extensionsUnavailable(error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!state.loaded)
              const LinearProgressIndicator()
            else if (state.extensions.isEmpty)
              EmptyState(
                icon: Icons.extension_outlined,
                title: l10n.extensionsEmptyTitle,
                body: l10n.extensionsEmptyBody,
              )
            else
              for (final extension in state.extensions)
                _ExtensionTile(extension: extension),
            SettingsGroup(
              title: l10n.extensionOptions,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.lyrics_outlined),
                  title: Text(l10n.extensionAutoLyrics),
                  subtitle: Text(l10n.extensionAutoLyricsBody),
                  value: settings.autoFetchLyrics,
                  onChanged: ref
                      .read(settingsProvider.notifier)
                      .setAutoFetchLyrics,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.developer_mode_outlined),
                  title: Text(l10n.extensionDeveloperMode),
                  subtitle: Text(l10n.extensionDeveloperModeBody),
                  value: settings.extensionDeveloperMode,
                  onChanged: ref
                      .read(settingsProvider.notifier)
                      .setExtensionDeveloperMode,
                ),
                if (settings.extensionDeveloperMode)
                  ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: Text(l10n.extensionLoadFolder),
                    subtitle: Text(l10n.extensionLoadFolderBody),
                    onTap: () => _loadFolder(context, ref),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtensionTile extends ConsumerWidget {
  const _ExtensionTile({required this.extension});

  final ExtensionInfo extension;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final manifest = extension.manifest;
    final status = extensionStatus(l10n, extension);
    final attention =
        extension.degraded ||
        !extension.supported ||
        (extension.enabled && extension.missingSecrets.isNotEmpty);
    return ListTile(
      leading: CircleAvatar(
        child: Icon(
          manifest.capabilities.isEmpty
              ? Icons.extension_outlined
              : capabilityIcon(manifest.capabilities.first),
        ),
      ),
      title: Text(manifest.name),
      subtitle: Text(
        [
          l10n.extensionVersion(manifest.version),
          for (final capability in manifest.capabilities)
            capabilityLabel(l10n, capability),
          ?status,
        ].join(' · '),
        style: attention ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      trailing: Switch(
        value: extension.enabled,
        onChanged: (enabled) => ref
            .read(extensionsProvider.notifier)
            .setEnabled(extension.id, enabled),
      ),
      onTap: () => context.push('/extensions/detail/${extension.id}'),
    );
  }
}
