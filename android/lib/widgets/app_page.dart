// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';
import 'package:kalao/widgets/app_sliver_header.dart';

/// A scrolling page under Mornye's collapsing large-title header: a pushed
/// page with a back button, or a tab root ([AppPage.tab]).
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    this.actions,
    required this.children,
    this.floatingActionButton,
    this.progress,
    this.padding = const EdgeInsets.only(bottom: 32),
  }) : _tab = false;

  const AppPage.tab({
    super.key,
    required this.title,
    this.actions,
    required this.children,
    this.floatingActionButton,
    this.progress,
    this.padding = const EdgeInsets.only(bottom: 32),
  }) : _tab = true;

  final String title;
  final List<Widget>? actions;
  final List<Widget> children;
  final Widget? floatingActionButton;

  /// Shown under the header while work runs; 0–1, or `double.nan` for an
  /// indeterminate bar. Null hides it.
  final double? progress;
  final EdgeInsetsGeometry padding;
  final bool _tab;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    return Scaffold(
      floatingActionButton: floatingActionButton,
      body: CustomScrollView(
        slivers: [
          if (_tab)
            AppSliverHeader.tabRoot(title: title, actions: actions)
          else
            AppSliverHeader.page(title: title, actions: actions),
          if (value != null)
            SliverToBoxAdapter(
              child: LinearProgressIndicator(value: value.isNaN ? null : value),
            ),
          SliverPadding(
            padding: padding,
            sliver: SliverList.list(children: children),
          ),
        ],
      ),
    );
  }
}

/// [AppPage] for a [body] that scrolls itself (a reorderable list, a list
/// with pull to refresh): the header collapses ahead of it.
class AppScrollPage extends StatelessWidget {
  const AppScrollPage({
    super.key,
    required this.title,
    this.actions,
    required this.body,
    this.floatingActionButton,
  }) : _tab = false;

  const AppScrollPage.tab({
    super.key,
    required this.title,
    this.actions,
    required this.body,
    this.floatingActionButton,
  }) : _tab = true;

  final String title;
  final List<Widget>? actions;
  final Widget body;
  final Widget? floatingActionButton;
  final bool _tab;

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: floatingActionButton,
    body: NestedScrollView(
      headerSliverBuilder: (context, _) => [
        if (_tab)
          AppSliverHeader.tabRoot(title: title, actions: actions)
        else
          AppSliverHeader.page(title: title, actions: actions),
      ],
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: body,
      ),
    ),
  );
}
