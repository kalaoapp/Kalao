// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';

/// Lyric text sizes S–XXL (Mornye's lyrics size setting), as a scale on the
/// base lyric font size.
enum LyricsSize {
  s(0.8),
  m(1.0),
  l(1.2),
  xl(1.45),
  xxl(1.75);

  const LyricsSize(this.scale);

  final double scale;
}

/// How Chinese lyrics are shown (FEATURES 2.5). The lyrics are stored as
/// imported; the variant is applied for display.
enum ChineseVariant {
  asWritten(null),
  simplified('t2s'),
  traditional('s2t'),
  taiwan('s2tw'),
  hongKong('s2hk');

  const ChineseVariant(this.conversion);

  /// The OpenCC conversion, or null to show the lyrics as written.
  final String? conversion;
}

/// How often a scheduled backup runs (FEATURES 7.4). A due backup runs when
/// the app is next opened or resumed (ADR-016).
enum BackupSchedule {
  off(null),
  daily(Duration(days: 1)),
  weekly(Duration(days: 7));

  const BackupSchedule(this.interval);

  final Duration? interval;
}

/// App preferences, stored as one JSON object in shared_preferences.
/// Unknown or missing keys fall back to defaults, so adding a field never
/// breaks an existing install. Secrets never go here (secure storage).
@immutable
class AppSettings {
  const AppSettings({
    this.setupCompleted = false,
    this.themeMode = ThemeMode.system,
    this.localeTag,
    this.verboseLogging = false,
    this.dynamicColor = false,
    this.lyricsSize = LyricsSize.m,
    this.customFontPath,
    this.showPinyin = true,
    this.wordSweep = true,
    this.tapLatencyMs = 40,
    this.showFurigana = true,
    this.showRomaji = false,
    this.showTranslation = true,
    this.chineseVariant = ChineseVariant.asWritten,
    this.countdown = true,
    this.keepScreenOn = true,
    this.tutorialSeen = false,
    this.whatsNewVersion,
    this.backupFolderUri,
    this.backupSchedule = BackupSchedule.off,
    this.backupKeep = 5,
    this.backupIncludeMedia = false,
    this.checkUpdates = true,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    setupCompleted: json['setupCompleted'] as bool? ?? false,
    themeMode:
        ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system,
    localeTag: json['localeTag'] as String?,
    verboseLogging: json['verboseLogging'] as bool? ?? false,
    dynamicColor: json['dynamicColor'] as bool? ?? false,
    lyricsSize:
        LyricsSize.values.asNameMap()[json['lyricsSize']] ?? LyricsSize.m,
    customFontPath: json['customFontPath'] as String?,
    showPinyin: json['showPinyin'] as bool? ?? true,
    wordSweep: json['wordSweep'] as bool? ?? true,
    tapLatencyMs: (json['tapLatencyMs'] as num?)?.toInt() ?? 40,
    showFurigana: json['showFurigana'] as bool? ?? true,
    showRomaji: json['showRomaji'] as bool? ?? false,
    showTranslation: json['showTranslation'] as bool? ?? true,
    chineseVariant:
        ChineseVariant.values.asNameMap()[json['chineseVariant']] ??
        ChineseVariant.asWritten,
    countdown: json['countdown'] as bool? ?? true,
    keepScreenOn: json['keepScreenOn'] as bool? ?? true,
    tutorialSeen: json['tutorialSeen'] as bool? ?? false,
    whatsNewVersion: json['whatsNewVersion'] as String?,
    backupFolderUri: json['backupFolderUri'] as String?,
    backupSchedule:
        BackupSchedule.values.asNameMap()[json['backupSchedule']] ??
        BackupSchedule.off,
    backupKeep: ((json['backupKeep'] as num?)?.toInt() ?? 5).clamp(1, 30),
    backupIncludeMedia: json['backupIncludeMedia'] as bool? ?? false,
    checkUpdates: json['checkUpdates'] as bool? ?? true,
  );

  /// Keys that describe this device or this install rather than the user's
  /// preferences: they are left out of backups and kept on restore.
  static const deviceKeys = {
    'setupCompleted',
    'tutorialSeen',
    'whatsNewVersion',
    'customFontPath',
    'backupFolderUri',
    'backupSchedule',
    'backupKeep',
    'backupIncludeMedia',
  };

  /// `settings.json` in a backup (DATA_MODEL.md §3).
  Map<String, dynamic> toBackupJson() => {
    for (final MapEntry(:key, :value) in toJson().entries)
      if (!deviceKeys.contains(key)) key: value,
  };

  /// Preferences from a backup's `settings.json`, with this device's
  /// [deviceKeys] values from [device].
  static AppSettings restoredFrom(
    Map<String, dynamic> backup,
    AppSettings device,
  ) {
    final local = device.toJson();
    return AppSettings.fromJson({
      for (final MapEntry(:key, :value) in backup.entries)
        if (!deviceKeys.contains(key)) key: value,
      for (final key in deviceKeys) key: local[key],
    });
  }

  /// The user finished the first-run setup.
  final bool setupCompleted;
  final ThemeMode themeMode;

  /// A BCP-47 tag from `supportedLocales`, or null to follow the system.
  final String? localeTag;

  /// Keep debug and info log entries (Dart and Rust).
  final bool verboseLogging;

  /// Material You colours from the wallpaper (Android 12+) instead of the
  /// Kalao brand scheme. Off by default so the app looks like Kalao.
  final bool dynamicColor;
  final LyricsSize lyricsSize;

  /// A font file copied into app storage, used for lyrics; null = default.
  final String? customFontPath;

  /// Show the pinyin layer above Chinese lyrics.
  final bool showPinyin;

  /// Sweep the active line of timed lyrics (word by word when the lyrics
  /// have word timing, linearly otherwise).
  final bool wordSweep;

  /// How long a tap takes to register, subtracted from taps in the sync
  /// editor (0–200 ms).
  final int tapLatencyMs;

  /// Show furigana above kanji in Japanese lyrics.
  final bool showFurigana;

  /// Show romaji under Japanese lyrics.
  final bool showRomaji;

  /// Show a line's translation under it when the lyrics have one.
  final bool showTranslation;
  final ChineseVariant chineseVariant;

  /// Count down to the next line after a long gap in Karaoke mode.
  final bool countdown;

  /// Keep the screen on while singing in Karaoke mode.
  final bool keepScreenOn;

  /// The tutorial was shown (or skipped) after setup.
  final bool tutorialSeen;

  /// The app version whose What's New page was last shown.
  final String? whatsNewVersion;

  /// The SAF folder (tree URI) scheduled backups are written to.
  final String? backupFolderUri;
  final BackupSchedule backupSchedule;

  /// Scheduled backups kept in the folder (1–30); older ones are deleted.
  final int backupKeep;

  /// Scheduled backups include imported audio (large).
  final bool backupIncludeMedia;

  /// Check GitHub Releases for a newer version once a day (FEATURES 9.8).
  final bool checkUpdates;

  Map<String, dynamic> toJson() => {
    'setupCompleted': setupCompleted,
    'themeMode': themeMode.name,
    'localeTag': localeTag,
    'verboseLogging': verboseLogging,
    'dynamicColor': dynamicColor,
    'lyricsSize': lyricsSize.name,
    'customFontPath': customFontPath,
    'showPinyin': showPinyin,
    'wordSweep': wordSweep,
    'tapLatencyMs': tapLatencyMs,
    'showFurigana': showFurigana,
    'showRomaji': showRomaji,
    'showTranslation': showTranslation,
    'chineseVariant': chineseVariant.name,
    'countdown': countdown,
    'keepScreenOn': keepScreenOn,
    'tutorialSeen': tutorialSeen,
    'whatsNewVersion': whatsNewVersion,
    'backupFolderUri': backupFolderUri,
    'backupSchedule': backupSchedule.name,
    'backupKeep': backupKeep,
    'backupIncludeMedia': backupIncludeMedia,
    'checkUpdates': checkUpdates,
  };

  AppSettings copyWith({
    bool? setupCompleted,
    ThemeMode? themeMode,
    String? Function()? localeTag,
    bool? verboseLogging,
    bool? dynamicColor,
    LyricsSize? lyricsSize,
    String? Function()? customFontPath,
    bool? showPinyin,
    bool? wordSweep,
    int? tapLatencyMs,
    bool? showFurigana,
    bool? showRomaji,
    bool? showTranslation,
    ChineseVariant? chineseVariant,
    bool? countdown,
    bool? keepScreenOn,
    bool? tutorialSeen,
    String? Function()? whatsNewVersion,
    String? Function()? backupFolderUri,
    BackupSchedule? backupSchedule,
    int? backupKeep,
    bool? backupIncludeMedia,
    bool? checkUpdates,
  }) => AppSettings(
    setupCompleted: setupCompleted ?? this.setupCompleted,
    themeMode: themeMode ?? this.themeMode,
    localeTag: localeTag != null ? localeTag() : this.localeTag,
    verboseLogging: verboseLogging ?? this.verboseLogging,
    dynamicColor: dynamicColor ?? this.dynamicColor,
    lyricsSize: lyricsSize ?? this.lyricsSize,
    customFontPath: customFontPath != null
        ? customFontPath()
        : this.customFontPath,
    showPinyin: showPinyin ?? this.showPinyin,
    wordSweep: wordSweep ?? this.wordSweep,
    tapLatencyMs: tapLatencyMs ?? this.tapLatencyMs,
    showFurigana: showFurigana ?? this.showFurigana,
    showRomaji: showRomaji ?? this.showRomaji,
    showTranslation: showTranslation ?? this.showTranslation,
    chineseVariant: chineseVariant ?? this.chineseVariant,
    countdown: countdown ?? this.countdown,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    tutorialSeen: tutorialSeen ?? this.tutorialSeen,
    whatsNewVersion: whatsNewVersion != null
        ? whatsNewVersion()
        : this.whatsNewVersion,
    backupFolderUri: backupFolderUri != null
        ? backupFolderUri()
        : this.backupFolderUri,
    backupSchedule: backupSchedule ?? this.backupSchedule,
    backupKeep: backupKeep ?? this.backupKeep,
    backupIncludeMedia: backupIncludeMedia ?? this.backupIncludeMedia,
    checkUpdates: checkUpdates ?? this.checkUpdates,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.setupCompleted == setupCompleted &&
      other.themeMode == themeMode &&
      other.localeTag == localeTag &&
      other.verboseLogging == verboseLogging &&
      other.dynamicColor == dynamicColor &&
      other.lyricsSize == lyricsSize &&
      other.customFontPath == customFontPath &&
      other.showPinyin == showPinyin &&
      other.wordSweep == wordSweep &&
      other.tapLatencyMs == tapLatencyMs &&
      other.showFurigana == showFurigana &&
      other.showRomaji == showRomaji &&
      other.showTranslation == showTranslation &&
      other.chineseVariant == chineseVariant &&
      other.countdown == countdown &&
      other.keepScreenOn == keepScreenOn &&
      other.tutorialSeen == tutorialSeen &&
      other.whatsNewVersion == whatsNewVersion &&
      other.backupFolderUri == backupFolderUri &&
      other.backupSchedule == backupSchedule &&
      other.backupKeep == backupKeep &&
      other.backupIncludeMedia == backupIncludeMedia &&
      other.checkUpdates == checkUpdates;

  @override
  int get hashCode => Object.hashAll([
    setupCompleted,
    themeMode,
    localeTag,
    verboseLogging,
    dynamicColor,
    lyricsSize,
    customFontPath,
    showPinyin,
    wordSweep,
    tapLatencyMs,
    showFurigana,
    showRomaji,
    showTranslation,
    chineseVariant,
    countdown,
    keepScreenOn,
    tutorialSeen,
    whatsNewVersion,
    backupFolderUri,
    backupSchedule,
    backupKeep,
    backupIncludeMedia,
    checkUpdates,
  ]);
}
