// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/l10n/supported_locales.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_sync_screen.dart';
import 'package:kalao/screens/main_shell.dart';
import 'package:kalao/screens/now_playing_screen.dart';
import 'package:kalao/screens/settings/backup_screen.dart';
import 'package:kalao/screens/settings/log_screen.dart';
import 'package:kalao/screens/settings/privacy_screen.dart';
import 'package:kalao/screens/stats_screen.dart';
import 'package:kalao/screens/setup_screen.dart';
import 'package:kalao/screens/tutorial_screen.dart';
import 'package:kalao/screens/whats_new_screen.dart';
import 'package:kalao/theme/app_theme.dart';

/// First screen for the current app state, as in Mornye's
/// `initialLocationForAppState`: setup, then the tutorial (once), then
/// What's New (once per version after an update), then the shell.
String initialLocationForAppState({
  required bool setupCompleted,
  bool tutorialSeen = true,
  String? whatsNewVersion = AppInfo.version,
}) {
  if (!setupCompleted) return '/setup';
  if (!tutorialSeen) return '/tutorial';
  if (whatsNewVersion != AppInfo.version) return '/whats-new';
  return '/';
}

final routerProvider = Provider<GoRouter>((ref) {
  final location = ref.watch(
    settingsProvider.select(
      (settings) => initialLocationForAppState(
        setupCompleted: settings.setupCompleted,
        tutorialSeen: settings.tutorialSeen,
        whatsNewVersion: settings.whatsNewVersion,
      ),
    ),
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/tutorial',
        builder: (context, state) => const TutorialScreen(),
      ),
      GoRoute(
        path: '/whats-new',
        builder: (context, state) => const WhatsNewScreen(),
      ),
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(path: '/setup', builder: (context, state) => const SetupScreen()),
      GoRoute(
        path: '/player',
        builder: (context, state) => const NowPlayingScreen(),
        routes: [
          GoRoute(
            path: 'sync',
            builder: (context, state) => const LyricsSyncScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/settings/logs',
        builder: (context, state) => const LogScreen(),
      ),
      GoRoute(
        path: '/settings/backup',
        builder: (context, state) => const BackupScreen(),
      ),
      GoRoute(
        path: '/settings/privacy',
        builder: (context, state) => const PrivacyScreen(),
      ),
      GoRoute(path: '/stats', builder: (context, state) => const StatsScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class KalaoApp extends ConsumerWidget {
  const KalaoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    // Material You (Mornye's dynamic_color_wrapper): wallpaper colours on
    // Android 12+ when enabled, otherwise the Kalao brand scheme.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final useDynamic =
            settings.dynamicColor &&
            lightDynamic != null &&
            darkDynamic != null;
        return MaterialApp.router(
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            useDynamic
                ? AppTheme.fromDynamic(lightDynamic)
                : AppTheme.seededScheme(Brightness.light),
          ),
          darkTheme: AppTheme.build(
            useDynamic
                ? AppTheme.fromDynamic(darkDynamic)
                : AppTheme.seededScheme(Brightness.dark),
          ),
          themeMode: settings.themeMode,
          locale: localeForTag(settings.localeTag),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        );
      },
    );
  }
}
