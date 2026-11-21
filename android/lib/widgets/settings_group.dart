// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
//
// The Material style of Mornye's `settings_group.dart`: neutral grouped
// fills, connected rows separated by 2dp gaps, primary section headers.
import 'package:flutter/material.dart';
import 'package:kalao/theme/app_tokens.dart';

/// The neutral grouped fill used by settings groups and grouped lists.
Color settingsGroupColor(BuildContext context) {
  final theme = Theme.of(context);
  final surface = theme.colorScheme.surface;
  return theme.brightness == Brightness.dark
      ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), surface)
      : Color.alphaBlend(Colors.black.withValues(alpha: 0.04), surface);
}

/// Horizontal margin of grouped content: the 16dp edge, centred within
/// [AppTokens.maxContentWidth] on wide screens.
double settingsHorizontalInset(double maxWidth) =>
    AppTokens.space16 +
    (maxWidth.isFinite && maxWidth > AppTokens.maxContentWidth
        ? (maxWidth - AppTokens.maxContentWidth) / 2
        : 0);

/// Corners of one row in a connected group: the card radius at the [first]
/// and [last] ends, tight corners between rows.
BorderRadius connectedRowRadius({required bool first, required bool last}) {
  const outer = Radius.circular(AppTokens.radiusCard);
  const inner = Radius.circular(AppTokens.radiusRowInner);
  return BorderRadius.vertical(
    top: first ? outer : inner,
    bottom: last ? outer : inner,
  );
}

/// Whether [children] are rows, each drawn as its own connected surface:
/// several children are unless a spacer or divider shows a hand-built form;
/// one child is when it is a standard row.
bool settingsGroupHasRows(List<Widget> children) {
  bool standard(Widget child) =>
      child is SettingsItem ||
      child is SettingsSwitchItem ||
      child is ListTile ||
      child is SwitchListTile;
  return switch (children) {
    [] => false,
    [final only] => standard(only),
    _ => !children.any((child) => child is SizedBox || child is Divider),
  };
}

/// Rows inside a connected group draw no dividers: the gaps separate them.
bool settingsRowsConnected(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ConnectedRowsScope>() != null;

class _ConnectedRowsScope extends InheritedWidget {
  const _ConnectedRowsScope({required super.child});

  @override
  bool updateShouldNotify(_ConnectedRowsScope oldWidget) => false;
}

/// A group of settings rows, with an optional [title] header above it.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.connected,
    this.margin,
  });

  final String? title;
  final List<Widget> children;

  /// Whether each child is one row with its own connected surface; null
  /// decides from the children ([settingsGroupHasRows]).
  final bool? connected;

  /// Replaces the default edge inset.
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final color = settingsGroupColor(context);
    final rows = connected ?? settingsGroupHasRows(children);
    final Widget group;
    if (rows) {
      final last = children.length - 1;
      group = _ConnectedRowsScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, row) in children.indexed) ...[
              if (index > 0) const SizedBox(height: AppTokens.rowGap),
              Material(
                color: color,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: connectedRowRadius(
                    first: index == 0,
                    last: index == last,
                  ),
                ),
                child: row,
              ),
            ],
          ],
        ),
      );
    } else {
      group = Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );
    }
    final inset = margin == null
        ? LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: settingsHorizontalInset(constraints.maxWidth),
                vertical: AppTokens.space4,
              ),
              child: group,
            ),
          )
        : Padding(padding: margin!, child: group);
    final header = title;
    if (header == null) return inset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsSectionHeader(title: header),
        inset,
      ],
    );
  }
}

/// A section title above a [SettingsGroup], aligned with its rows' content.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset =
            settingsHorizontalInset(constraints.maxWidth) + AppTokens.space16;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            inset,
            AppTokens.space24,
            inset,
            AppTokens.space8,
          ),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One settings row: icon, title, subtitle, an optional [footer] below them
/// and a [trailing] widget (a chevron when it only opens something).
class SettingsItem extends StatelessWidget {
  const SettingsItem({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.footer,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.enabled = true,
  });

  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? footer;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = enabled ? null : scheme.outline;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: enabled ? onTap : null,
          splashColor: scheme.primary.withValues(alpha: 0.12),
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.rowPaddingH,
              vertical: AppTokens.rowPaddingV,
            ),
            child: Row(
              children: [
                if (icon case final icon?) ...[
                  Icon(
                    icon,
                    size: 24,
                    color: muted ?? iconColor ?? scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppTokens.rowIconGap),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: muted,
                        ),
                      ),
                      if (subtitle case final subtitle?) ...[
                        const SizedBox(height: AppTokens.space2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: muted ?? scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (footer case final footer?) ...[
                        const SizedBox(height: AppTokens.space8),
                        footer,
                      ],
                    ],
                  ),
                ),
                if (trailing case final trailing?) ...[
                  const SizedBox(width: AppTokens.space8),
                  trailing,
                ] else if (onTap != null) ...[
                  const SizedBox(width: AppTokens.space8),
                  Icon(
                    Icons.chevron_right,
                    size: AppTokens.rowChevronSize,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          _RowDivider(indented: icon != null),
      ],
    );
  }
}

/// A row with a switch; tapping anywhere on it toggles.
class SettingsSwitchItem extends StatelessWidget {
  const SettingsSwitchItem({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.showDivider = true,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final change = onChanged;
    final muted = change == null ? scheme.outline : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MergeSemantics(
          child: InkWell(
            onTap: change == null ? null : () => change(!value),
            splashColor: scheme.primary.withValues(alpha: 0.12),
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.rowPaddingH,
                vertical: AppTokens.rowPaddingVCompact,
              ),
              child: Row(
                children: [
                  if (icon case final icon?) ...[
                    Icon(
                      icon,
                      size: 24,
                      color: muted ?? scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.rowIconGap),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: muted,
                          ),
                        ),
                        if (subtitle case final subtitle?) ...[
                          const SizedBox(height: AppTokens.space2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted ?? scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppTokens.space8),
                  Switch(value: value, onChanged: change),
                ],
              ),
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          _RowDivider(indented: icon != null),
      ],
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider({required this.indented});

  final bool indented;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: indented ? AppTokens.rowIconDividerIndent : AppTokens.rowPaddingH,
    endIndent: AppTokens.rowPaddingH,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
  );
}
