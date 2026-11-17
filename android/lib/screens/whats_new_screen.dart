import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Shown once after an update (Mornye's What's New screen with Kalao
/// content): what this version added. Continuing records the version, and
/// the router moves on to the shell.
class WhatsNewScreen extends ConsumerWidget {
  const WhatsNewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final items = [
      (Icons.mic_external_on_outlined, l10n.whatsNewModes),
      (Icons.tune, l10n.whatsNewKeyTempo),
      (Icons.gradient, l10n.whatsNewTimedLyrics),
      (Icons.queue_music, l10n.whatsNewQueue),
      (Icons.translate, l10n.whatsNewLanguages),
    ];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(AppTokens.space24),
                    children: [
                      Text(
                        l10n.whatsNewTitle(AppInfo.version),
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: AppTokens.space16),
                      for (final (icon, text) in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(icon, color: theme.colorScheme.primary),
                          title: Text(text),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppTokens.space24),
                  child: FilledButton(
                    onPressed: () => ref
                        .read(settingsProvider.notifier)
                        .setWhatsNewVersion(AppInfo.version),
                    child: Text(l10n.whatsNewContinue),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
