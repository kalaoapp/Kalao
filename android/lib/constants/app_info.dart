// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.

/// Static facts about this build.
class AppInfo {
  static const String appName = 'Kalao';

  /// Strict semver (the extension engine parses it). Set it with
  /// `scripts/bump_version.sh`, which also updates pubspec.yaml.
  static const String version = '0.2.1-alpha';

  /// Extension developer mode exists only in alpha and beta builds; a
  /// stable release never offers it, whatever the settings say.
  static final bool developerModeAvailable = isTestBuild(version);

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

/// Whether the semver [version] is an alpha or beta pre-release
/// (`1.0.0-alpha`, `1.2.0-beta.3`); release candidates and stable versions
/// are not.
bool isTestBuild(String version) {
  final core = version.split('+').first;
  final dash = core.indexOf('-');
  if (dash < 0) return false;
  final pre = core.substring(dash + 1).toLowerCase();
  return pre.startsWith('alpha') || pre.startsWith('beta');
}
