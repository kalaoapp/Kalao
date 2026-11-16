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
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/services/custom_font_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/settings_group.dart';

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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTokens.space24),
        children: [
          SettingsGroup(
            title: l10n.settingsAppearance,
            children: [
              const ThemeModeTile(),
              SwitchListTile(
                secondary: const Icon(Icons.palette_outlined),
                title: Text(l10n.settingsDynamicColor),
                subtitle: Text(l10n.settingsDynamicColorSubtitle),
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
              SwitchListTile(
                secondary: const Icon(Icons.translate),
                title: Text(l10n.lyricsShowPinyin),
                value: settings.showPinyin,
                onChanged: notifier.setShowPinyin,
              ),
            ],
          ),
          SettingsGroup(
            title: l10n.settingsDiagnostics,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.bug_report_outlined),
                title: Text(l10n.settingsVerboseLogging),
                subtitle: Text(l10n.settingsVerboseLoggingSubtitle),
                value: settings.verboseLogging,
                onChanged: notifier.setVerboseLogging,
              ),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: Text(l10n.settingsViewLogs),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/logs'),
              ),
            ],
          ),
          SettingsGroup(
            title: l10n.settingsAbout,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.aboutVersion),
                subtitle: const Text(AppInfo.version),
              ),
              const _EngineTile(),
              ListTile(
                leading: const Icon(Icons.code),
                title: Text(l10n.aboutSource),
                subtitle: const Text(AppInfo.githubUrl),
              ),
              ListTile(
                leading: const Icon(Icons.gavel_outlined),
                title: Text(l10n.aboutLicenses),
                subtitle: Text(l10n.aboutCredits),
                trailing: const Icon(Icons.chevron_right),
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
      ),
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
    return ListTile(
      leading: const Icon(Icons.memory),
      title: Text(l10n.aboutEngine),
      subtitle: Text(subtitle),
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
    return ListTile(
      leading: const Icon(Icons.translate),
      title: Text(l10n.settingsLanguage),
      subtitle: Text(
        current == null ? l10n.languageSystem : localeDisplayName(current),
      ),
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
