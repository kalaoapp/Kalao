import 'package:flutter/material.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/theme/app_tokens.dart';

/// The privacy statement (FEATURES 9.6): what stays on the device and
/// the few network requests the app makes, and only when.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sections = [
      (l10n.privacyLocalTitle, l10n.privacyLocalBody),
      (l10n.privacyNetworkTitle, l10n.privacyNetworkBody),
      (l10n.privacyBackupTitle, l10n.privacyBackupBody),
      (l10n.privacyDiagnosticsTitle, l10n.privacyDiagnosticsBody),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.space16),
        children: [
          Text(l10n.privacyIntro, style: theme.textTheme.bodyLarge),
          for (final (title, body) in sections) ...[
            const SizedBox(height: AppTokens.space24),
            Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: AppTokens.space8),
            Text(body, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
