import 'package:flutter/foundation.dart';

/// The engine's `playerState` (also each `player_position_stream` event).
@immutable
class EnginePlayerState {
  const EnginePlayerState({
    this.songId,
    this.sources = const [],
    this.layout,
    this.durationMs,
    this.positionMs = 0,
    this.playing = false,
    this.completed = false,
    this.buffering = false,
    this.vocalLevel = 1,
    this.volume = 1,
    this.tempo = 1,
    this.error,
  });

  factory EnginePlayerState.fromJson(Map<String, dynamic> json) =>
      EnginePlayerState(
        songId: json['songId'] as String?,
        sources: [
          for (final source in json['sources'] as List<dynamic>? ?? const [])
            source as String,
        ],
        layout: json['layout'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        playing: json['playing'] as bool? ?? false,
        completed: json['completed'] as bool? ?? false,
        buffering: json['buffering'] as bool? ?? false,
        vocalLevel: (json['vocalLevel'] as num?)?.toDouble() ?? 1,
        volume: (json['volume'] as num?)?.toDouble() ?? 1,
        tempo: (json['tempo'] as num?)?.toDouble() ?? 1,
        error: json['error'] as String?,
      );

  static const idle = EnginePlayerState();

  final String? songId;
  final List<String> sources;

  /// `single`, `pair` or `stems`.
  final String? layout;
  final int? durationMs;
  final int positionMs;
  final bool playing;
  final bool completed;
  final bool buffering;

  /// 1 = original vocals, 0 = instrumental only.
  final double vocalLevel;
  final double volume;

  /// Playback speed (1 = normal); positions are always song time.
  final double tempo;
  final String? error;

  Duration get position => Duration(milliseconds: positionMs);
  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  bool get canSwitch => layout == 'pair' || layout == 'stems';

  @override
  bool operator ==(Object other) =>
      other is EnginePlayerState &&
      other.songId == songId &&
      other.positionMs == positionMs &&
      other.playing == playing &&
      other.completed == completed &&
      other.buffering == buffering &&
      other.vocalLevel == vocalLevel &&
      other.volume == volume &&
      other.tempo == tempo &&
      other.layout == layout &&
      other.durationMs == durationMs &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    songId,
    positionMs,
    playing,
    completed,
    buffering,
    vocalLevel,
    volume,
    tempo,
    layout,
    durationMs,
    error,
  );
}
