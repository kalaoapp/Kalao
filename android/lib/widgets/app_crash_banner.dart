// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/services/app_crash_service.dart';
import 'package:kalao/services/external_links.dart';

/// Shown once after a native crash. The report never leaves the device unless
/// the user copies it or opens a pre-filled GitHub issue and submits it.
class AppCrashBanner extends StatelessWidget {
  const AppCrashBanner({
    super.key,
    required this.report,
    required this.onDismissed,
  });

  final CrashReport report;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return MaterialBanner(
      leading: const Icon(Icons.report_problem_outlined),
      content: Text(l10n.crashBannerTitle),
      actions: [
        TextButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            await Clipboard.setData(ClipboardData(text: report.shareText));
            messenger.showSnackBar(SnackBar(content: Text(l10n.crashCopied)));
          },
          child: Text(l10n.crashBannerCopy),
        ),
        TextButton(
          onPressed: () => openExternalUrl(
            githubIssueUrl(
              title: l10n.crashIssueTitle,
              body: '```\n${report.shareText}\n```',
            ),
          ),
          child: Text(l10n.crashBannerReport),
        ),
        TextButton(
          onPressed: () async {
            await AppCrashService.clearLastCrash();
            onDismissed();
          },
          child: Text(l10n.crashBannerDismiss),
        ),
      ],
    );
  }
}
