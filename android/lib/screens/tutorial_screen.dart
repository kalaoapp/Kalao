import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/theme/app_tokens.dart';

/// A short tour after setup (Mornye's tutorial screen with Kalao content):
/// importing, lyrics, the two modes and the queue. Finishing or skipping it
/// marks it seen, and the router moves on to the shell.
class TutorialScreen extends ConsumerStatefulWidget {
  const TutorialScreen({super.key});

  @override
  ConsumerState<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends ConsumerState<TutorialScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final settings = ref.read(settingsProvider.notifier);
    // A new install has nothing new to be told about.
    await settings.setWhatsNewVersion(AppInfo.version);
    await settings.completeTutorial();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final pages = [
      (
        Icons.library_add_outlined,
        l10n.tutorialImportTitle,
        l10n.tutorialImportBody,
      ),
      (
        Icons.lyrics_outlined,
        l10n.tutorialLyricsTitle,
        l10n.tutorialLyricsBody,
      ),
      (
        Icons.mic_external_on_outlined,
        l10n.tutorialModesTitle,
        l10n.tutorialModesBody,
      ),
      (Icons.queue_music, l10n.tutorialQueueTitle, l10n.tutorialQueueBody),
    ];
    final last = _page == pages.length - 1;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [
          if (!last)
            TextButton(onPressed: _finish, child: Text(l10n.tutorialSkip)),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: pages.length,
                onPageChanged: (page) => setState(() => _page = page),
                itemBuilder: (context, index) {
                  final (icon, title, body) = pages[index];
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppTokens.space32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              icon,
                              size: 72,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: AppTokens.space24),
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: AppTokens.space12),
                            Text(
                              body,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Semantics(
              label: l10n.tutorialPage(_page + 1, pages.length),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index < pages.length; index++)
                      Padding(
                        padding: const EdgeInsets.all(AppTokens.space4),
                        child: Icon(
                          Icons.circle,
                          size: 8,
                          color: index == _page
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppTokens.space24),
              child: FilledButton(
                onPressed: last
                    ? _finish
                    : () => _pages.nextPage(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : AppTokens.motionMedium,
                        curve: Curves.easeOutCubic,
                      ),
                child: Text(last ? l10n.tutorialDone : l10n.tutorialNext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
