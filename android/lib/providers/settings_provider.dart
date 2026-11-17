// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _log = AppLogger('Settings');
const _settingsKey = 'app_settings';

/// Opened once in `main` and injected with `overrideWithValue`.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('sharedPreferencesProvider was not overridden'),
);

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return AppSettings.fromJson(json);
    } on FormatException catch (error) {
      _log.w('Settings were unreadable; using defaults', error);
    }
    return const AppSettings();
  }

  Future<void> _save(AppSettings next) async {
    if (next == state) return;
    state = next;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_settingsKey, jsonEncode(next.toJson()));
  }

  Future<void> completeSetup() => _save(state.copyWith(setupCompleted: true));

  Future<void> setThemeMode(ThemeMode mode) =>
      _save(state.copyWith(themeMode: mode));

  Future<void> setLocaleTag(String? tag) =>
      _save(state.copyWith(localeTag: () => tag));

  Future<void> setDynamicColor(bool value) =>
      _save(state.copyWith(dynamicColor: value));

  Future<void> setLyricsSize(LyricsSize size) =>
      _save(state.copyWith(lyricsSize: size));

  Future<void> setCustomFontPath(String? path) =>
      _save(state.copyWith(customFontPath: () => path));

  Future<void> setShowPinyin(bool value) =>
      _save(state.copyWith(showPinyin: value));

  Future<void> setWordSweep(bool value) =>
      _save(state.copyWith(wordSweep: value));

  Future<void> setTapLatencyMs(int value) =>
      _save(state.copyWith(tapLatencyMs: value.clamp(0, 200)));

  Future<void> setShowFurigana(bool value) =>
      _save(state.copyWith(showFurigana: value));

  Future<void> setShowRomaji(bool value) =>
      _save(state.copyWith(showRomaji: value));

  Future<void> setShowTranslation(bool value) =>
      _save(state.copyWith(showTranslation: value));

  Future<void> setChineseVariant(ChineseVariant value) =>
      _save(state.copyWith(chineseVariant: value));

  Future<void> setCountdown(bool value) =>
      _save(state.copyWith(countdown: value));

  Future<void> setKeepScreenOn(bool value) =>
      _save(state.copyWith(keepScreenOn: value));

  Future<void> completeTutorial() => _save(state.copyWith(tutorialSeen: true));

  Future<void> setWhatsNewVersion(String version) =>
      _save(state.copyWith(whatsNewVersion: () => version));

  Future<void> setBackupFolderUri(String? uri) =>
      _save(state.copyWith(backupFolderUri: () => uri));

  Future<void> setBackupSchedule(BackupSchedule value) =>
      _save(state.copyWith(backupSchedule: value));

  Future<void> setBackupKeep(int value) =>
      _save(state.copyWith(backupKeep: value.clamp(1, 30)));

  Future<void> setBackupIncludeMedia(bool value) =>
      _save(state.copyWith(backupIncludeMedia: value));

  Future<void> setCheckUpdates(bool value) =>
      _save(state.copyWith(checkUpdates: value));

  /// Applies preferences restored from a backup (device keys stay).
  Future<void> restore(AppSettings restored) => _save(restored);

  Future<void> setVerboseLogging(bool value) async {
    await _save(state.copyWith(verboseLogging: value));
    LogBuffer().verbose = value;
    try {
      await PlatformBridge.setLoggingEnabled(value);
    } catch (error) {
      _log.w('Could not change native logging', error);
    }
  }
}
