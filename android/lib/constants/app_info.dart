// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.

/// Static facts about this build. Set [version] with scripts/bump_version.sh, which also updates pubspec.yaml.
class AppInfo {
  static const String appName = 'Kalao';
  static const String version = '0.1.05-alpha';

  /// [version] as strict semver (leading zeros dropped, `0.1.05` → `0.1.5`),
  /// for the extension engine's `minKalao` checks.
  static final String semver = version.replaceAllMapped(
    RegExp(r'^(\d+)\.(\d+)\.(\d+)'),
    (m) => [for (var i = 1; i <= 3; i++) int.parse(m[i]!)].join('.'),
  );
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
