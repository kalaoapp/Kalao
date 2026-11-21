import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';

/// Update check against GitHub Releases and the verified download.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late Directory cache;

  setUp(() async {
    backend = FakeBackend()..install();
    cache = await Directory.systemTemp.createTemp('kalao-updates-');
  });
  tearDown(() async {
    backend.uninstall();
    if (cache.existsSync()) await cache.delete(recursive: true);
  });

  const apkBytes = [1, 2, 3, 4];
  String fnv(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(64, '0');
  }

  Map<String, Object?> release(String tag) => {
    'tag_name': tag,
    'body': '## Changes\n- Backups',
    'html_url': 'https://github.com/kalaoapp/Kalao/releases/tag/$tag',
    'assets': [
      for (final label in ['arm64', 'arm32', 'universal'])
        {
          'name': 'Kalao-${tag.substring(1)}-$label.apk',
          'browser_download_url': 'https://dl/$label.apk',
          'size': apkBytes.length,
        },
      {
        'name': 'SHA256SUMS.txt',
        'browser_download_url': 'https://dl/sums',
        'size': 10,
      },
    ],
  };

  MockClient github(String tag, {String? sums}) => MockClient((request) async {
    final url = request.url.toString();
    if (url.contains('api.github.com')) {
      expect(request.headers['User-Agent'], startsWith('Kalao/'));
      return http.Response(jsonEncode(release(tag)), 200);
    }
    if (url == 'https://dl/sums') {
      return http.Response(
        sums ??
            '${fnv(apkBytes)}  Kalao-${tag.substring(1)}-arm64.apk\n'
                '${'0' * 64}  Kalao-${tag.substring(1)}-arm32.apk\n',
        200,
      );
    }
    return http.Response.bytes(apkBytes, 200);
  });

  test('versions compare numerically, pre-releases first', () {
    expect(isNewerVersion('0.2.0', '0.1.0'), isTrue);
    expect(isNewerVersion('0.10.0', '0.9.9'), isTrue);
    expect(isNewerVersion('0.1.0', '0.1.0'), isFalse);
    expect(isNewerVersion('0.1.0', '0.2.0'), isFalse);
    expect(isNewerVersion('0.2.0', '0.2.0-beta'), isTrue);
    expect(isNewerVersion('0.2.0-beta', '0.2.0'), isFalse);
    expect(isNewerVersion('0.2.0-alpha', '0.1.1-alpha'), isTrue);
  });

  test('the app version is strict semver', () {
    expect(
      AppInfo.version,
      matches(RegExp(r'^(0|[1-9]\d*)(\.(0|[1-9]\d*)){2}(-[0-9A-Za-z.-]+)?$')),
    );
  });

  test('the APK follows the device ABI, else universal', () {
    final r = AppRelease.fromJson(release('v0.2.0'));
    expect(r.version, '0.2.0');
    expect(
      r.apkFor(['arm64-v8a', 'armeabi-v7a'])!.name,
      'Kalao-0.2.0-arm64.apk',
    );
    expect(r.apkFor(['armeabi-v7a'])!.name, 'Kalao-0.2.0-arm32.apk');
    expect(r.apkFor(['x86_64'])!.name, 'Kalao-0.2.0-universal.apk');
    expect(r.checksums!.name, 'SHA256SUMS.txt');
    expect(
      checksumFor(
        '${'a' * 64} *Kalao-0.2.0-arm64.apk',
        'Kalao-0.2.0-arm64.apk',
      ),
      'a' * 64,
    );
  });

  test('check finds a newer release; same or no release is quiet', () async {
    final service = UpdateService(client: github('v9.0.0'), cacheDir: cache);
    expect((await service.checkForUpdate())!.version, '9.0.0');
    expect(
      await UpdateService(
        client: github('v0.1.0'),
        cacheDir: cache,
      ).checkForUpdate(),
      isNull,
    );
    expect(
      await UpdateService(
        client: MockClient((_) async => http.Response('', 404)),
        cacheDir: cache,
      ).checkForUpdate(),
      isNull,
    );
  });

  test('a download is kept only when its checksum matches', () async {
    final service = UpdateService(client: github('v9.0.0'), cacheDir: cache);
    final r = (await service.checkForUpdate())!;
    final progress = <double?>[];
    final file = await service.download(
      r,
      r.apkFor(['arm64-v8a'])!,
      onProgress: progress.add,
    );
    expect(await file.readAsBytes(), apkBytes);
    expect(progress.last, 1.0);

    await expectLater(
      service.download(r, r.apkFor(['armeabi-v7a'])!),
      throwsA(isA<UpdateException>()),
    );
    expect(
      cache.listSync().map((f) => f.path.split(Platform.pathSeparator).last),
      ['Kalao-9.0.0-arm64.apk'],
    );
    await service.clearDownloads();
    expect(cache.existsSync(), isFalse);
  });

  test('the daily check runs once a day and only when enabled', () async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(jsonEncode(release('v9.0.0')), 200);
    });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        updateServiceProvider.overrideWithValue(
          UpdateService(client: client, cacheDir: cache),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    final now = DateTime(2026, 11, 18, 9);
    expect((await controller.checkIfDue(now: now))!.version, '9.0.0');
    expect(container.read(updateControllerProvider), isA<UpdateAvailable>());
    expect(
      await controller.checkIfDue(now: now.add(const Duration(hours: 3))),
      isNull,
    );
    expect(requests, 1);
    await container.read(settingsProvider.notifier).setCheckUpdates(false);
    expect(
      await controller.checkIfDue(now: now.add(const Duration(days: 2))),
      isNull,
    );
    expect(requests, 1);
  });

  test('a rate-limited check says so and waits a day', () async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        '{"message":"API rate limit exceeded"}',
        403,
        headers: {'x-ratelimit-remaining': '0'},
      );
    });
    final service = UpdateService(client: client, cacheDir: cache);
    await expectLater(
      service.checkForUpdate(),
      throwsA(isA<UpdateRateLimitedException>()),
    );
    // Any other 403 stays a plain failure.
    await expectLater(
      UpdateService(
        client: MockClient((_) async => http.Response('', 403)),
        cacheDir: cache,
      ).checkForUpdate(),
      throwsA(
        isA<UpdateException>().having(
          (error) => error is UpdateRateLimitedException,
          'rate limited',
          isFalse,
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        updateServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    final now = DateTime(2026, 11, 18, 9);
    requests = 0;
    expect(await controller.checkIfDue(now: now), isNull);
    expect(
      await controller.checkIfDue(now: now.add(const Duration(hours: 1))),
      isNull,
    );
    expect(requests, 1);
  });

  test('install hands the verified APK to the installer', () async {
    SharedPreferences.setMockInitialValues({});
    final service = UpdateService(client: github('v9.0.0'), cacheDir: cache);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        updateServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    final r = (await service.checkForUpdate())!;
    await container.read(updateControllerProvider.notifier).install(r);
    final install = backend.calls.singleWhere((c) => c.method == 'installApk');
    expect(
      (install.arguments as Map)['path'],
      endsWith('Kalao-9.0.0-arm64.apk'),
    );
    expect(container.read(updateControllerProvider), isA<UpdateAvailable>());
  });
}
