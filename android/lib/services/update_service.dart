// Mornye's update_checker.dart + apk_downloader.dart flow, sized for Kalao
// (IMPLEMENTATION.md §14): read the latest GitHub release, pick the APK for
// this device, and only on the user's request download it, check its
// SHA-256 against the release's SHA256SUMS.txt and hand it to the installer.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:path/path.dart' as p;

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// GitHub refused the check because this network used up its hourly quota
/// of anonymous API calls (shared by everyone behind the same address).
class UpdateRateLimitedException extends UpdateException {
  const UpdateRateLimitedException(super.message);

  /// The quota error for a 403 or 429 [response], or null for other errors.
  static UpdateRateLimitedException? from(http.Response response) {
    final status = response.statusCode;
    final headers = response.headers;
    final limited =
        status == 429 ||
        (status == 403 && headers['x-ratelimit-remaining'] == '0');
    if (!limited) return null;
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    final minutes = reset == null
        ? null
        : (DateTime.fromMillisecondsSinceEpoch(
                    reset * 1000,
                  ).difference(DateTime.now()).inSeconds /
                  60)
              .ceil();
    return UpdateRateLimitedException(
      minutes == null || minutes <= 0
          ? 'GitHub is limiting requests from this network; try again later'
          : 'GitHub is limiting requests from this network; try again in '
                '$minutes min',
    );
  }
}

@immutable
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.bytes = 0});

  final String name;
  final Uri url;
  final int bytes;
}

/// The latest GitHub release.
@immutable
class AppRelease {
  const AppRelease({
    required this.version,
    required this.notes,
    required this.page,
    required this.assets,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
    version: (json['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), ''),
    notes: json['body'] as String? ?? '',
    page: Uri.parse(
      json['html_url'] as String? ?? '${AppInfo.githubUrl}/releases',
    ),
    assets: [
      for (final asset in json['assets'] as List<dynamic>? ?? const [])
        if (asset case {
          'name': final String name,
          'browser_download_url': final String url,
        })
          ReleaseAsset(
            name: name,
            url: Uri.parse(url),
            bytes: (asset['size'] as num?)?.toInt() ?? 0,
          ),
    ],
  );

  final String version;

  /// The changelog, as Markdown text (shown as plain text).
  final String notes;
  final Uri page;
  final List<ReleaseAsset> assets;

  /// The APK for the first of [abis] (the device's, best first) that this
  /// release has, else the universal one.
  ReleaseAsset? apkFor(List<String> abis) {
    ReleaseAsset? named(String label) =>
        assets.where((a) => a.name == 'Kalao-$version-$label.apk').firstOrNull;
    for (final abi in abis) {
      final label = switch (abi) {
        'arm64-v8a' => 'arm64',
        'armeabi-v7a' => 'arm32',
        'x86_64' => 'x86_64',
        _ => null,
      };
      final asset = label == null ? null : named(label);
      if (asset != null) return asset;
    }
    return named('universal');
  }

  ReleaseAsset? get checksums =>
      assets.where((a) => a.name == 'SHA256SUMS.txt').firstOrNull;
}

/// Whether [candidate] (`1.2.3`, optionally `-suffix`) is newer than
/// [current]. A pre-release sorts before its release.
bool isNewerVersion(String candidate, String current) {
  (List<int>, bool) parse(String version) {
    final [core, ...pre] = version.split('-');
    final parts = [
      for (final part in core.split('.')) int.tryParse(part) ?? 0,
      0,
      0,
      0,
    ].take(3).toList();
    return (parts, pre.isNotEmpty);
  }

  final (a, aPre) = parse(candidate);
  final (b, bPre) = parse(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return !aPre && bPre;
}

/// The SHA-256 listed for [name] in a `sha256sum` file.
String? checksumFor(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
    if (match != null && match.group(2)!.trim() == name) {
      return match.group(1)!.toLowerCase();
    }
  }
  return null;
}

class UpdateService {
  UpdateService({http.Client? client, required this.cacheDir})
    : _client = client ?? http.Client();

  static final latestUrl = Uri.parse(
    'https://api.github.com/repos/${AppInfo.githubRepo}/releases/latest',
  );

  final http.Client _client;
  final Directory cacheDir;

  /// The latest release when it is newer than this build, else null.
  Future<AppRelease?> checkForUpdate() async {
    final response = await _client
        .get(
          latestUrl,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': '${AppInfo.appName}/${AppInfo.version}',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) return null; // no release yet
    final limited = UpdateRateLimitedException.from(response);
    if (limited != null) throw limited;
    if (response.statusCode != 200) {
      throw UpdateException('GitHub answered ${response.statusCode}');
    }
    final release = AppRelease.fromJson(
      (jsonDecode(response.body) as Map).cast<String, dynamic>(),
    );
    return isNewerVersion(release.version, AppInfo.version) ? release : null;
  }

  /// Downloads [apk], checks it against the release checksums and returns
  /// the file. [onProgress] gets 0–1, or null when the size is unknown.
  Future<File> download(
    AppRelease release,
    ReleaseAsset apk, {
    void Function(double? progress)? onProgress,
  }) async {
    final sumsAsset = release.checksums;
    if (sumsAsset == null) {
      throw const UpdateException('The release has no checksums file');
    }
    final sums = await _client
        .get(sumsAsset.url)
        .timeout(const Duration(seconds: 30));
    final expected = sums.statusCode == 200
        ? checksumFor(sums.body, apk.name)
        : null;
    if (expected == null) {
      throw UpdateException('No checksum for ${apk.name}');
    }

    await cacheDir.create(recursive: true);
    final file = File(p.join(cacheDir.path, apk.name));
    final partial = File('${file.path}.part');
    final response = await _client.send(http.Request('GET', apk.url));
    if (response.statusCode != 200) {
      throw UpdateException('Download failed (${response.statusCode})');
    }
    final total = response.contentLength ?? apk.bytes;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total > 0 ? received / total : null);
      }
    } finally {
      await sink.close();
    }
    final actual = await PlatformBridge.hashFile(
      partial.path,
      requestId: 'update-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (actual != expected) {
      await partial.delete();
      throw const UpdateException(
        'The download does not match the published checksum',
      );
    }
    if (file.existsSync()) await file.delete();
    return partial.rename(file.path);
  }

  /// Removes downloaded APKs (after an install, or on the next start).
  Future<void> clearDownloads() async {
    if (!cacheDir.existsSync()) return;
    await cacheDir.delete(recursive: true);
  }
}
