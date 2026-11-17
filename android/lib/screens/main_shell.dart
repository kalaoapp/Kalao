// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/backup_provider.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/screens/home_tab.dart';
import 'package:kalao/screens/library_screen.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/screens/settings/settings_tab.dart';
import 'package:kalao/screens/shared_files.dart';
import 'package:kalao/services/app_crash_service.dart';
import 'package:kalao/widgets/app_crash_banner.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/mini_player.dart';
import 'package:kalao/widgets/update_dialog.dart';

/// The tabbed home of the app. Tabs keep their state while hidden.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;
  CrashReport? _crash;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    AppCrashService.readLastCrash().then((report) {
      if (mounted && report != null) setState(() => _crash = report);
    });
    // On start and resume: files opened with Kalao (M4.12), then a due
    // scheduled backup (ADR-016).
    _lifecycle = AppLifecycleListener(onResume: _onForeground);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onForeground();
      unawaited(_offerUpdate());
    });
  }

  /// The daily update check (FEATURES 9.8), on start only.
  Future<void> _offerUpdate() async {
    final release = await ref
        .read(updateControllerProvider.notifier)
        .checkIfDue();
    if (release != null && mounted) await showUpdateDialog(context, release);
  }

  void _onForeground() {
    if (!mounted) return;
    unawaited(handleSharedFiles(context, ref));
    unawaited(ref.read(backupControllerProvider.notifier).runScheduledIfDue());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tabs = <Widget>[
      const HomeTab(),
      const LibraryScreen(),
      const QueueTab(),
      _PlaceholderTab(
        title: l10n.navExtensions,
        icon: Icons.extension_outlined,
        emptyTitle: l10n.extensionsEmptyTitle,
        emptyBody: l10n.extensionsEmptyBody,
      ),
      const SettingsTab(),
    ];
    final crash = _crash;
    return Scaffold(
      body: Column(
        children: [
          if (crash != null)
            SafeArea(
              bottom: false,
              child: AppCrashBanner(
                report: crash,
                onDismissed: () => setState(() => _crash = null),
              ),
            ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: crash != null,
              child: IndexedStack(index: _index, children: tabs),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (index) => setState(() => _index = index),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home),
                label: l10n.navHome,
              ),
              NavigationDestination(
                icon: const Icon(Icons.library_music_outlined),
                selectedIcon: const Icon(Icons.library_music),
                label: l10n.navLibrary,
              ),
              NavigationDestination(
                icon: const Icon(Icons.queue_music_outlined),
                selectedIcon: const Icon(Icons.queue_music),
                label: l10n.navQueue,
              ),
              NavigationDestination(
                icon: const Icon(Icons.extension_outlined),
                selectedIcon: const Icon(Icons.extension),
                label: l10n.navExtensions,
              ),
              NavigationDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings),
                label: l10n.navSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A tab whose feature arrives in a later milestone (ROADMAP.md).
class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({
    required this.title,
    required this.icon,
    required this.emptyTitle,
    required this.emptyBody,
  });

  final String title;
  final IconData icon;
  final String emptyTitle;
  final String emptyBody;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: EmptyState(icon: icon, title: emptyTitle, body: emptyBody),
  );
}
