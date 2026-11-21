// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/l10n/supported_locales.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/screens/import_sheet.dart';
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/services/custom_font_service.dart';
import 'package:kalao/services/external_links.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/app_page.dart';
import 'package:kalao/widgets/settings_group.dart';
import 'package:kalao/widgets/update_dialog.dart';

/// Engine details for About; null when the Rust library is unavailable.
final backendInfoProvider = FutureProvider<BackendInfo?>((ref) async {
  try {
    return await PlatformBridge.getBackendInfo();
  } catch (_) {
    return null;
  }
});

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return AppPage.tab(
      title: l10n.settingsTitle,
      padding: const EdgeInsets.only(bottom: AppTokens.space24),
      children: [
        SettingsGroup(
          title: l10n.settingsAppearance,
          children: [
            const ThemeModeTile(),
            SettingsSwitchItem(
              icon: Icons.palette_outlined,
              title: l10n.settingsDynamicColor,
              subtitle: l10n.settingsDynamicColorSubtitle,
              value: settings.dynamicColor,
              onChanged: notifier.setDynamicColor,
            ),
            const LanguageTile(),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsLyrics,
          children: [
            const LyricsSizeTile(),
            const _CustomFontTile(),
            SettingsSwitchItem(
              icon: Icons.translate,
              title: l10n.lyricsShowPinyin,
              value: settings.showPinyin,
              onChanged: notifier.setShowPinyin,
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.navExtensions,
          children: [
            SettingsItem(
              icon: Icons.extension_outlined,
              title: l10n.navExtensions,
              subtitle: l10n.settingsExtensionsSubtitle,
              onTap: () => context.push('/settings/extensions'),
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsData,
          children: [
            SettingsItem(
              icon: Icons.file_upload_outlined,
              title: l10n.importSettingsTitle,
              subtitle: l10n.importSettingsSubtitle,
              onTap: () => pickAndImport(context, ref),
            ),
            SettingsItem(
              icon: Icons.folder_outlined,
              title: l10n.foldersTitle,
              subtitle: l10n.foldersSettingsSubtitle,
              onTap: () => context.push('/settings/folders'),
            ),
            SettingsItem(
              icon: Icons.backup_outlined,
              title: l10n.backupTitle,
              subtitle: l10n.backupSettingsSubtitle,
              onTap: () => context.push('/settings/backup'),
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsDiagnostics,
          children: [
            SettingsSwitchItem(
              icon: Icons.bug_report_outlined,
              title: l10n.settingsVerboseLogging,
              subtitle: l10n.settingsVerboseLoggingSubtitle,
              value: settings.verboseLogging,
              onChanged: notifier.setVerboseLogging,
            ),
            SettingsItem(
              icon: Icons.article_outlined,
              title: l10n.settingsViewLogs,
              onTap: () => context.push('/settings/logs'),
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsAbout,
          children: [
            SettingsItem(
              icon: Icons.info_outline,
              title: l10n.aboutVersion,
              subtitle: AppInfo.version,
            ),
            SettingsSwitchItem(
              icon: Icons.update,
              title: l10n.updateCheckSetting,
              subtitle: l10n.updateCheckSettingSubtitle,
              value: settings.checkUpdates,
              onChanged: notifier.setCheckUpdates,
            ),
            const _CheckUpdateTile(),
            const _EngineTile(),
            SettingsItem(
              icon: Icons.code,
              title: l10n.aboutSource,
              subtitle: AppInfo.githubUrl,
              trailing: const Icon(Icons.open_in_new),
              onTap: () => openExternalUrl(Uri.parse(AppInfo.githubUrl)),
            ),
            SettingsItem(
              icon: Icons.privacy_tip_outlined,
              title: l10n.privacyTitle,
              onTap: () => context.push('/settings/privacy'),
            ),
            SettingsItem(
              icon: Icons.gavel_outlined,
              title: l10n.aboutLicenses,
              subtitle: l10n.aboutCredits,
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.appName,
                applicationVersion: AppInfo.version,
                applicationLegalese:
                    '${AppInfo.copyright}\n${AppInfo.license}\n\n${AppInfo.mornyeCredit}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Custom lyric font (Mornye's custom_font_setting): pick a .ttf/.otf file,
/// or reset to the theme font.
class _CustomFontTile extends ConsumerWidget {
  const _CustomFontTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final path = ref.watch(settingsProvider.select((s) => s.customFontPath));
    final family = ref.watch(customFontFamilyProvider).asData?.value;
    final notifier = ref.read(settingsProvider.notifier);
    return ListTile(
      leading: const Icon(Icons.font_download_outlined),
      title: Text(l10n.settingsCustomFont),
      subtitle: Text(
        family == null
            ? l10n.settingsCustomFontDefault
            : l10n.settingsCustomFontSample,
        style: TextStyle(fontFamily: family),
      ),
      trailing: path == null
          ? null
          : IconButton(
              tooltip: l10n.settingsCustomFontReset,
              icon: const Icon(Icons.restart_alt),
              onPressed: () => notifier.setCustomFontPath(null),
            ),
      onTap: () async {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: customFontExtensions,
        );
        if (files.isEmpty) return;
        final stored = await storeCustomFont(
          ref.read(libraryServicesProvider).storage.fonts,
          files.first.name,
          await files.first.readAsBytes(),
        );
        await notifier.setCustomFontPath(stored);
      },
    );
  }
}

class _CheckUpdateTile extends ConsumerStatefulWidget {
  const _CheckUpdateTile();

  @override
  ConsumerState<_CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends ConsumerState<_CheckUpdateTile> {
  bool _checking = false;

  Future<void> _check() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      final release = await ref
          .read(updateControllerProvider.notifier)
          .checkNow();
      if (!mounted) return;
      if (release == null) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.updateUpToDate)));
      } else {
        await showUpdateDialog(context, release);
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.updateCheckFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsItem(
      icon: Icons.system_update_outlined,
      title: l10n.updateCheckNow,
      trailing: _checking
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _checking ? null : _check,
    );
  }
}

class _EngineTile extends ConsumerWidget {
  const _EngineTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final info = ref.watch(backendInfoProvider);
    final subtitle = switch (info) {
      AsyncData(value: final value?) =>
        '${value.name} ${value.version} (${value.os}/${value.arch})',
      AsyncLoading() => '…',
      _ => l10n.aboutEngineUnavailable,
    };
    return SettingsItem(
      icon: Icons.memory,
      title: l10n.aboutEngine,
      subtitle: subtitle,
    );
  }
}

/// Theme mode picker, shared by settings and first-run setup.
class ThemeModeTile extends ConsumerWidget {
  const ThemeModeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: Text(l10n.settingsTheme),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: AppTokens.space8),
        child: SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text(l10n.themeSystem),
            ),
            ButtonSegment(value: ThemeMode.light, label: Text(l10n.themeLight)),
            ButtonSegment(value: ThemeMode.dark, label: Text(l10n.themeDark)),
          ],
          selected: {mode},
          onSelectionChanged: (selection) =>
              ref.read(settingsProvider.notifier).setThemeMode(selection.first),
        ),
      ),
    );
  }
}

/// Language picker, shared by settings and first-run setup.
class LanguageTile extends ConsumerWidget {
  const LanguageTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tag = ref.watch(settingsProvider.select((s) => s.localeTag));
    final current = localeForTag(tag);
    return SettingsItem(
      icon: Icons.translate,
      title: l10n.settingsLanguage,
      subtitle: current == null
          ? l10n.languageSystem
          : localeDisplayName(current),
      onTap: () async {
        final picked = await showDialog<_LanguageChoice>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(l10n.settingsLanguage),
            children: [
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, const _LanguageChoice(null)),
                child: Text(l10n.languageSystem),
              ),
              for (final locale in kalaoSupportedLocales)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(
                    context,
                    _LanguageChoice(localeTag(locale)),
                  ),
                  child: Text(localeDisplayName(locale)),
                ),
            ],
          ),
        );
        if (picked != null) {
          await ref.read(settingsProvider.notifier).setLocaleTag(picked.tag);
        }
      },
    );
  }
}

/// Distinguishes "follow the system" (tag null) from a cancelled dialog.
class _LanguageChoice {
  const _LanguageChoice(this.tag);

  final String? tag;
}
