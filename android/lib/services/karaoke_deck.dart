import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Deck');

/// The playback deck over the Rust engine (IMPLEMENTATION.md §2): commands go
/// through [PlatformBridge]; state arrives on `player_position_stream` at
/// 30 Hz while playing, and [position] interpolates between events with a
/// local clock so lyrics move smoothly at 60 fps.
///
/// Mornye's `music_player_service.dart` drives several deck types; Kalao has
/// one engine, so this class is the deck and the player service talks to it
/// directly.
class KaraokeDeck {
  /// [now] is a monotonic clock (tests pass a simulated one).
  KaraokeDeck({Stream<Object?>? events, Duration Function()? now})
    : _events =
          events ??
          const EventChannel(
            'com.brinsley.kalao/player_position_stream',
          ).receiveBroadcastStream(),
      _now = now ?? _stopwatchClock();

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final Stream<Object?> _events;
  final Duration Function() _now;
  final _states = StreamController<EnginePlayerState>.broadcast();
  StreamSubscription<Object?>? _subscription;
  EnginePlayerState _state = EnginePlayerState.idle;
  Duration _stateAt = Duration.zero;

  Stream<EnginePlayerState> get states => _states.stream;
  EnginePlayerState get state => _state;

  /// The engine position now: the last reported position plus the song time
  /// since it was reported while playing (wall time × tempo), capped at the
  /// duration.
  Duration get position {
    if (!_state.playing) return _state.position;
    final elapsed = (_now() - _stateAt) * _state.tempo;
    final estimate = _state.position + elapsed;
    final duration = _state.duration;
    return duration != null && estimate > duration ? duration : estimate;
  }

  void start() {
    _subscription ??= _events.listen((event) {
      if (event is String) {
        _apply(
          EnginePlayerState.fromJson(
            (jsonDecode(event) as Map).cast<String, dynamic>(),
          ),
        );
      }
    }, onError: (Object error) => _log.w('Position stream error', error));
  }

  void _apply(EnginePlayerState next) {
    _stateAt = _now();
    if (next == _state) return;
    _state = next;
    _states.add(next);
  }

  Future<EnginePlayerState> _run(Future<EnginePlayerState> command) async {
    final next = await command;
    _apply(next);
    return next;
  }

  Future<EnginePlayerState> load({
    required String songId,
    required Map<String, String> sources,
    Duration start = Duration.zero,
  }) => _run(
    PlatformBridge.playerLoad(songId: songId, sources: sources, start: start),
  );

  Future<EnginePlayerState> play() => _run(PlatformBridge.playerPlay());

  Future<EnginePlayerState> pause() => _run(PlatformBridge.playerPause());

  Future<EnginePlayerState> stop() => _run(PlatformBridge.playerStop());

  Future<EnginePlayerState> seek(Duration position) => _run(
    PlatformBridge.playerSeek(
      position < Duration.zero ? Duration.zero : position,
    ),
  );

  Future<EnginePlayerState> setVolume(double volume) =>
      _run(PlatformBridge.playerSetVolume(volume));

  /// Playback speed 0.5–1.5 (the sync editor slows down while timing).
  Future<EnginePlayerState> setTempo(double rate) =>
      _run(PlatformBridge.playerSetTempo(rate));

  /// Vocal-guide blend: 1 = full vocals, 0 = instrumental only.
  Future<EnginePlayerState> setVocalLevel(double level) =>
      _run(PlatformBridge.playerSetStemGains(vocals: level.clamp(0, 1)));

  Future<EnginePlayerState> switchTrack({required bool instrumental}) => _run(
    PlatformBridge.playerSwitchTrack(
      instrumental ? 'instrumental' : 'original',
    ),
  );

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _states.close();
  }
}
