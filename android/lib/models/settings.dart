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
  );

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
      other.tapLatencyMs == tapLatencyMs;

  @override
  int get hashCode => Object.hash(
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
  );
}
