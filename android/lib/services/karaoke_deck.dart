import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;

import 'package:flutter/services.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Deck');

/// The playback deck over the Rust engine (IMPLEMENTATION.md §2): commands go
/// through [PlatformBridge]; the engine publishes its state on
/// `player_position_stream` at 30 Hz while playing, stamped with the
/// CLOCK_MONOTONIC instant it was taken, and [position] interpolates from
/// that instant so lyrics move smoothly at 60 fps and channel delays do not
/// shift them.
class KaraokeDeck {
  /// [now] is the monotonic clock events are stamped with (tests pass a
  /// simulated one).
  KaraokeDeck({Stream<Object?>? events, Duration Function()? now})
    : _events =
          events ??
          const EventChannel(
            'com.brinsley.kalao/player_position_stream',
          ).receiveBroadcastStream(),
      _now = now ?? _monotonicClock;

  /// CLOCK_MONOTONIC, the clock Kotlin's `System.nanoTime()` reads on Android.
  static Duration _monotonicClock() => Duration(microseconds: Timeline.now);

  /// An event older than this (or from the future) means the clocks do not
  /// match; its arrival time is used instead.
  static const _maxEventAge = Duration(milliseconds: 250);

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
      // `{state, atMicros}` from the host; plain JSON text in tests.
      final (json, at) = switch (event) {
        {'state': final String state, 'atMicros': final int at} => (
          state,
          Duration(microseconds: at),
        ),
        final String state => (state, null),
        _ => (null, null),
      };
      if (json == null) return;
      _apply(
        EnginePlayerState.fromJson(
          (jsonDecode(json) as Map).cast<String, dynamic>(),
        ),
        at: at,
      );
    }, onError: (Object error) => _log.w('Position stream error', error));
  }

  void _apply(EnginePlayerState next, {Duration? at}) {
    final now = _now();
    final age = at == null ? null : now - at;
    _stateAt = age != null && !age.isNegative && age < _maxEventAge ? at! : now;
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

  /// Transposition in semitones, ±6.
  Future<EnginePlayerState> setKey(double semitones) =>
      _run(PlatformBridge.playerSetKey(semitones));

  /// Repeats [start]..[end]; both null clears the loop.
  Future<EnginePlayerState> setLoop({Duration? start, Duration? end}) =>
      _run(PlatformBridge.playerSetLoop(start: start, end: end));

  /// Playback speed 0.5–1.5 at the same pitch.
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
