// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Mornye's collapsing large-title header (Material style), for tab roots
/// and pushed settings-style pages.
class AppSliverHeader extends StatelessWidget {
  /// Root of a navigation tab: no back button.
  const AppSliverHeader.tabRoot({super.key, required this.title, this.actions})
    : _showLeading = false;

  /// A pushed page: a tonal back button, and the title slides clear of it
  /// as the header collapses.
  const AppSliverHeader.page({super.key, required this.title, this.actions})
    : _showLeading = true;

  final String title;
  final List<Widget>? actions;
  final bool _showLeading;

  /// Clears a 48dp icon button plus the toolbar margin.
  static const double _leadingClearance = 56;

  /// The content margin the expanded title lines up with.
  static const double _contentMargin = 24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topPadding = MediaQuery.paddingOf(context).top;
    final size = MediaQuery.sizeOf(context);
    // Short landscape windows give the large title less headroom.
    final shortened = size.height < size.width && size.height < 720
        ? AppTokens.headerExpandedHeight - 24
        : AppTokens.headerExpandedHeight;
    final expandedHeight = _showLeading
        ? math.max(shortened, AppTokens.headerExpandedHeight)
        : shortened;
    final maxHeight = expandedHeight + topPadding;
    final canPop = _showLeading && (ModalRoute.of(context)?.canPop ?? false);
    return SliverAppBar(
      expandedHeight: maxHeight,
      collapsedHeight: kToolbarHeight,
      pinned: true,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      leading: canPop
          ? Padding(
              padding: const EdgeInsetsDirectional.only(
                start: AppTokens.space4,
              ),
              child: IconButton.filledTonal(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerHighest,
                  foregroundColor: scheme.onSurface,
                ),
                onPressed: () => Navigator.maybePop(context),
              ),
            )
          : null,
      actions: actions,
      actionsPadding: const EdgeInsetsDirectional.only(end: AppTokens.space4),
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final settings = context
              .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
          final minExtent = settings?.minExtent ?? kToolbarHeight;
          final maxExtent = settings?.maxExtent ?? maxHeight;
          final current = settings?.currentExtent ?? constraints.maxHeight;
          final delta = maxExtent - minExtent;
          final expand = delta > 0
              ? ((current - minExtent) / delta).clamp(0.0, 1.0)
              : 0.0;
          final start = canPop
              ? _leadingClearance -
                    (_leadingClearance - _contentMargin) * expand
              : _contentMargin;
          final fontSize =
              AppTokens.headerCollapsedTitleSize +
              (AppTokens.headerExpandedTitleSize -
                      AppTokens.headerCollapsedTitleSize) *
                  expand;
          // Collapsed bars sit on a container tone and fade back to the
          // surface as they expand.
          return ColoredBox(
            color: Color.lerp(scheme.surfaceContainer, scheme.surface, expand)!,
            child: FlexibleSpaceBar(
              centerTitle: false,
              expandedTitleScale: 1,
              titlePadding: EdgeInsetsDirectional.only(
                start: start,
                end: AppTokens.space16,
                bottom: AppTokens.space16,
              ),
              title: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
