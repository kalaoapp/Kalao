// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.

/// Static facts about this build.
class AppInfo {
  static const String appName = 'Kalao';

  /// Strict semver (the extension engine parses it). Set it with
  /// `scripts/bump_version.sh`, which also updates pubspec.yaml.
  static const String version = '0.2.0-alpha';
  static const String license = 'GPL-3.0-only';
  static const String copyright = '© 2026 Brinsley Morrison';

  static const String githubRepo = 'kalaoapp/Kalao';
  static const String githubUrl = 'https://github.com/$githubRepo';
  static const String issuesUrl = '$githubUrl/issues/new';

  /// The only donation link. It opens in the browser; Kalao has no in-app
  /// payments and never checks whether someone donated.
  static const String donateUrl = 'https://ko-fi.com/brinsley';

  static const String mornyeCredit =
      'Built on Mornye (https://github.com/mornyeapp/Mornye), '
      'Copyright 2026 zarzet, LGPL-3.0-only.';
}
