// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/widgets.dart';

/// Locales offered in the UI, in the order shown in the language picker.
/// `zh` is Simplified Chinese; `zh_Hant` is Traditional Chinese.
const List<Locale> kalaoSupportedLocales = <Locale>[
  Locale('en'),
  Locale('zh'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  Locale('ja'),
];

/// The tag stored in settings for [locale] (`en`, `zh`, `zh-Hant`, `ja`).
String localeTag(Locale locale) => locale.toLanguageTag();

/// The supported locale for a stored [tag], or null for "follow the system".
Locale? localeForTag(String? tag) {
  if (tag == null) return null;
  for (final locale in kalaoSupportedLocales) {
    if (localeTag(locale) == tag) return locale;
  }
  return null;
}

/// Each language's name in itself, for the picker.
String localeDisplayName(Locale locale) => switch (localeTag(locale)) {
  'en' => 'English',
  'zh' => '简体中文',
  'zh-Hant' => '繁體中文',
  'ja' => '日本語',
  _ => localeTag(locale),
};

/// The UI locale outside a widget tree (notifications from background
/// work): the stored [tag], else the closest match to the system locale.
Locale appLocaleFor(String? tag, [Locale? system]) {
  final chosen = localeForTag(tag);
  if (chosen != null) return chosen;
  final device = system ?? WidgetsBinding.instance.platformDispatcher.locale;
  return switch (device.languageCode) {
    'zh'
        when device.scriptCode == 'Hant' ||
            const {'TW', 'HK', 'MO'}.contains(device.countryCode) =>
      kalaoSupportedLocales[2],
    'zh' => const Locale('zh'),
    'ja' => const Locale('ja'),
    _ => const Locale('en'),
  };
}
