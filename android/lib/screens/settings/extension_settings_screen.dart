// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/extensions/extension_install.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/app_sliver_header.dart';
import 'package:kalao/widgets/settings_group.dart';

/// Settings → Extensions (Mornye's Extensions settings page): provider
/// order, repositories, install from a file and the extension options.
/// The Extensions tab keeps the installed extensions and the store.
class ExtensionSettingsScreen extends ConsumerWidget {
  const ExtensionSettingsScreen({super.key});

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
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final repositories = ref.watch(
      extensionsProvider.select((state) => state.repositories.length),
    );
    final developerMode =
        AppInfo.developerModeAvailable && settings.extensionDeveloperMode;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.navExtensions),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.low_priority,
                  title: l10n.extensionPriority,
                  subtitle: l10n.extensionPrioritySubtitle,
                  onTap: () => context.push('/extensions/priority'),
                ),
                SettingsItem(
                  icon: Icons.storefront_outlined,
                  title: l10n.extensionRepositories,
                  subtitle: l10n.settingsRepositoriesCount(repositories),
                  onTap: () =>
                      context.push('/settings/extensions/repositories'),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Same edges as the groups.
                final inset = settingsHorizontalInset(constraints.maxWidth);
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    AppTokens.space16,
                    inset,
                    AppTokens.space8,
                  ),
                  child: FilledButton.icon(
                    onPressed: () => pickAndInstallExtension(context, ref),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.extensionInstallFromFile),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppTokens.space16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              title: l10n.extensionOptions,
              children: [
                SettingsSwitchItem(
                  icon: Icons.lyrics_outlined,
                  title: l10n.extensionAutoLyrics,
                  subtitle: l10n.extensionAutoLyricsBody,
                  value: settings.autoFetchLyrics,
                  onChanged: notifier.setAutoFetchLyrics,
                ),
                if (AppInfo.developerModeAvailable)
                  SettingsSwitchItem(
                    icon: Icons.developer_mode_outlined,
                    title: l10n.extensionDeveloperMode,
                    subtitle: l10n.extensionDeveloperModeBody,
                    value: settings.extensionDeveloperMode,
                    onChanged: notifier.setExtensionDeveloperMode,
                  ),
                if (developerMode)
                  SettingsItem(
                    icon: Icons.folder_open_outlined,
                    title: l10n.extensionLoadFolder,
                    subtitle: l10n.extensionLoadFolderBody,
                    onTap: () => _loadFolder(context, ref),
                  ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppTokens.space32)),
        ],
      ),
    );
  }
}
