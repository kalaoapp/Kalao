// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/app.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/services/app_crash_service.dart';
import 'package:kalao/services/app_state_database.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/external_links.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/services/playback_handler.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _log = AppLogger('App');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      AppCrashService.recordRuntimeError(details.exception, details.stack),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(AppCrashService.recordRuntimeError(error, stack));
    return true;
  };

  registerAppLicenses();
  final preferences = await SharedPreferences.getInstance();
  final services = await openLibraryServices();
  final handler = await _startMediaSession();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      libraryServicesProvider.overrideWithValue(services),
      audioHandlerProvider.overrideWithValue(handler),
      audioFocusEnabledProvider.overrideWithValue(true),
      updateServiceProvider.overrideWithValue(await openUpdateService()),
    ],
  );
  final verbose = container.read(settingsProvider).verboseLogging;
  LogBuffer().verbose = verbose || kDebugMode;
  unawaited(_startBackend(verbose));

  runApp(
    UncontrolledProviderScope(container: container, child: const KalaoApp()),
  );
}

/// Opens app storage and the three databases (DATA_MODEL.md §2).
Future<LibraryServices> openLibraryServices() async {
  final storage = AppStorage(await getApplicationSupportDirectory());
  await storage.ensure();
  final library = await LibraryDatabase.open(storage.libraryDb);
  return LibraryServices(
    storage: storage,
    library: library,
    history: await HistoryDatabase.open(storage.historyDb),
    appState: await AppStateDatabase.open(storage.appStateDb),
    importer: ImportService(
      library: library,
      storage: storage,
      convert: _convertWithFfmpeg,
    ),
  );
}

/// One-off import conversion to FLAC for codecs Symphonia lacks.
Future<bool> _convertWithFfmpeg(String input, String output) async {
  final session = await FFmpegKit.executeWithArguments([
    '-y', '-i', input, '-vn', '-map_metadata', '0', '-c:a', 'flac', output, //
  ]);
  final ok = ReturnCode.isSuccess(await session.getReturnCode());
  if (!ok) {
    _log.w('FFmpeg conversion failed: ${await session.getOutput()}');
    final partial = File(output);
    if (partial.existsSync()) await partial.delete();
  }
  return ok;
}

/// audio_service owns the cached engine and the media session; a failure
/// here leaves playback working without system controls.
Future<KalaoAudioHandler?> _startMediaSession() async {
  try {
    return await AudioService.init(
      builder: KalaoAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.brinsley.kalao.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_notification',
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (error, stack) {
    _log.e('Media session unavailable', error, stack);
    return null;
  }
}

/// The Android host initialises the Rust library before the first frame; this
/// syncs the logging preference and records the engine in the log.
Future<void> _startBackend(bool verbose) async {
  try {
    await PlatformBridge.setLoggingEnabled(verbose);
    final info = await PlatformBridge.getBackendInfo();
    _log.i(
      'Engine ${info.name} ${info.version} (${info.os}/${info.arch}), '
      '${info.methods.length} methods: ${jsonEncode(info.methods)}',
    );
  } catch (error, stack) {
    _log.e('Rust engine is unavailable', error, stack);
  }
}
