import 'package:flutter/material.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Keyboard and gamepad shortcuts of the Now playing screen (FEATURES 9.3),
/// opened with `?`.
Future<void> showShortcutsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ShortcutsSheet(),
    );

class ShortcutsSheet extends StatelessWidget {
  const ShortcutsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // (keyboard, gamepad, what it does)
    final rows = [
      ('Space', 'A', l10n.shortcutPlayPause),
      ('← / →', 'L1 / R1', l10n.shortcutSeek),
      ('↑ / ↓', 'D-pad ↑ / ↓', l10n.shortcutLine),
      ('S', 'X', l10n.shortcutSwitchTrack),
      ('L', 'Y', l10n.shortcutLoop),
      ('?', '', l10n.shortcutHelp),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space24,
          0,
          AppTokens.space24,
          AppTokens.space24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.shortcutsTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppTokens.space12),
            Table(
              columnWidths: const {
                0: IntrinsicColumnWidth(),
                1: IntrinsicColumnWidth(),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  children: [
                    for (final header in [
                      l10n.shortcutsKeyboard,
                      l10n.shortcutsGamepad,
                      '',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(
                          right: AppTokens.space16,
                          bottom: AppTokens.space8,
                        ),
                        child: Text(header, style: theme.textTheme.labelMedium),
                      ),
                  ],
                ),
                for (final (keyboard, gamepad, action) in rows)
                  TableRow(
                    children: [
                      for (final key in [keyboard, gamepad])
                        Padding(
                          padding: const EdgeInsets.only(
                            right: AppTokens.space16,
                            bottom: AppTokens.space8,
                          ),
                          child: Text(
                            key,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppTokens.space8,
                        ),
                        child: Text(action),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
