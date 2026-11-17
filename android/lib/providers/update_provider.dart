import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/services/update_service.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _log = AppLogger('Update');
const _checkedAtKey = 'update_checked_at';

/// Replaced in tests with one on a fake HTTP client.
final updateServiceProvider = Provider<UpdateService>(
  (ref) => throw StateError('updateServiceProvider was not overridden'),
);

/// Opens the service on the cache folder (`cache/updates/`, the folder the
/// installer's FileProvider shares).
Future<UpdateService> openUpdateService() async => UpdateService(
  cacheDir: Directory(p.join((await getTemporaryDirectory()).path, 'updates')),
);

/// Where the update flow is; the dialog follows it.
@immutable
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release);

  final AppRelease release;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.progress);

  final AppRelease release;

  /// 0–1, or null while the size is unknown.
  final double? progress;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.release, this.message);

  final AppRelease? release;
  final String message;
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// FEATURES 9.8: a daily check when enabled; downloading and installing
/// happen only when the user taps Update.
class UpdateController extends Notifier<UpdateState> {
  static const checkInterval = Duration(days: 1);

  @override
  UpdateState build() => const UpdateIdle();

  UpdateService get _service => ref.read(updateServiceProvider);

  /// On start: removes old downloads and checks once a day. Returns the
  /// release to offer, if any.
  Future<AppRelease?> checkIfDue({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final prefs = ref.read(sharedPreferencesProvider);
    if (!ref.read(settingsProvider).checkUpdates) return null;
    final last = prefs.getInt(_checkedAtKey);
    if (last != null &&
        at.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
            checkInterval) {
      return null;
    }
    unawaited(_service.clearDownloads().catchError((Object _) {}));
    try {
      final release = await _service.checkForUpdate();
      await prefs.setInt(_checkedAtKey, at.millisecondsSinceEpoch);
      if (release != null) state = UpdateAvailable(release);
      return release;
    } catch (error) {
      // Offline is normal; the next start tries again.
      _log.w('Update check failed', error);
      return null;
    }
  }

  /// "Check now" in Settings: always asks GitHub. Null = up to date.
  Future<AppRelease?> checkNow() async {
    final release = await _service.checkForUpdate();
    await ref
        .read(sharedPreferencesProvider)
        .setInt(_checkedAtKey, DateTime.now().millisecondsSinceEpoch);
    state = release == null ? const UpdateIdle() : UpdateAvailable(release);
    return release;
  }

  /// Downloads, verifies and opens the installer for [release].
  Future<void> install(AppRelease release) async {
    try {
      final apk = release.apkFor(await PlatformBridge.getSupportedAbis());
      if (apk == null) {
        throw const UpdateException('The release has no APK for this device');
      }
      state = UpdateDownloading(release, null);
      final file = await _service.download(
        release,
        apk,
        onProgress: (progress) => state = UpdateDownloading(release, progress),
      );
      state = UpdateAvailable(release);
      if (!await PlatformBridge.installApk(file.path)) {
        // Settings opened for "install unknown apps"; Update works after.
        _log.i('Waiting for permission to install apps');
      }
    } catch (error) {
      _log.w('Update failed', error);
      state = UpdateFailed(release, '$error');
    }
  }

  void dismiss() => state = const UpdateIdle();
}
