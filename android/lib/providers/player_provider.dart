import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/playback_handler.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Player');

/// Injected in `main` after `AudioService.init`; null in tests.
final audioHandlerProvider = Provider<KalaoAudioHandler?>((ref) => null);

final karaokeDeckProvider = Provider<KaraokeDeck>((ref) {
  final deck = KaraokeDeck()..start();
  ref.onDispose(deck.dispose);
  return deck;
});

@immutable
class NowPlaying {
  const NowPlaying({
    this.song,
    this.lyrics,
    this.engine = EnginePlayerState.idle,
    this.manualLine = 0,
  });

  final Song? song;
  final LyricDocument? lyrics;
  final EnginePlayerState engine;

  /// The highlighted line when stepping manually through untimed lyrics.
  final int manualLine;

  bool get isInstrumental => engine.canSwitch && engine.vocalLevel < 0.5;

  NowPlaying copyWith({
    Song? song,
    LyricDocument? Function()? lyrics,
    EnginePlayerState? engine,
    int? manualLine,
  }) => NowPlaying(
    song: song ?? this.song,
    lyrics: lyrics != null ? lyrics() : this.lyrics,
    engine: engine ?? this.engine,
    manualLine: manualLine ?? this.manualLine,
  );
}

final playerProvider = NotifierProvider<PlayerController, NowPlaying>(
  PlayerController.new,
);

/// Plays library songs on the engine, keeps history and the session for
/// "Continue singing", and drives the media session (Mornye's
/// music_player_service + playback_session_restore roles, sized for one deck
/// and no queue until M3.4).
class PlayerController extends Notifier<NowPlaying>
    implements PlaybackCommands {
  late KaraokeDeck _deck;
  KalaoAudioHandler? _handler;
  AudioFocus? _focus;
  StreamSubscription<EnginePlayerState>? _states;
  Timer? _sessionTimer;
  int? _playId;
  final _listened = Stopwatch();
  double _volume = 1;

  @override
  NowPlaying build() {
    _deck = ref.watch(karaokeDeckProvider);
    _handler = ref.watch(audioHandlerProvider)?..commands = this;
    _states = _deck.states.listen(_onEngine);
    final focus = _handler == null
        ? null
        : AudioFocus(
            this,
            isPlaying: () => state.engine.playing,
            setDucked: (ducked) =>
                _deck.setVolume(ducked ? _volume * 0.3 : _volume),
          );
    _focus = focus;
    unawaited(focus?.start());
    ref.onDispose(() {
      _states?.cancel();
      _sessionTimer?.cancel();
      focus?.dispose();
    });
    return const NowPlaying();
  }

  LibraryServices get _services => ref.read(libraryServicesProvider);

  void _onEngine(EnginePlayerState engine) {
    final wasPlaying = state.engine.playing;
    state = state.copyWith(engine: engine);
    if (engine.playing && !_listened.isRunning) _listened.start();
    if (!engine.playing && _listened.isRunning) _listened.stop();
    if (wasPlaying && !engine.playing) unawaited(_saveSession());
    _handler?.publish(state.song, engine);
  }

  /// Interpolated engine position for lyric display.
  Duration get position => _deck.position;

  /// The files to load for [song]: original + instrumental when both exist,
  /// otherwise whichever exists.
  static Map<String, String> sourcesFor(Song song) => {
    for (final file in song.media) file.kind.name: file.path,
  };

  /// Loads [song] (at [start]) and starts playing. [instrumental] picks the
  /// backing track when the song has one.
  Future<void> playSong(
    Song song, {
    Duration start = Duration.zero,
    bool? instrumental,
  }) async {
    await _finishPlay();
    final sources = sourcesFor(song);
    if (sources.isEmpty) return;
    final lyrics = await _services.library.lyrics(song.id);
    state = NowPlaying(song: song, lyrics: lyrics, engine: state.engine);
    await _deck.load(songId: '${song.id}', sources: sources, start: start);
    if (_deck.state.tempo != 1) await _deck.setTempo(1);
    final useBacking = instrumental ?? song.lastMode == PlayMode.karaoke.name;
    if (song.hasBacking) {
      await _deck.switchTrack(instrumental: useBacking);
    } else {
      await _deck.setVocalLevel(1);
    }
    await play();
    _playId = await _services.history.startPlay(
      songId: song.id,
      songKey: LibraryDatabase.songKey(
        song.title,
        song.artist,
        song.durationMs,
        null,
      ),
      mode: _mode,
    );
    _listened.reset();
    ref.read(libraryRevisionProvider.notifier).bump();
    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (state.engine.playing) unawaited(_saveSession());
    });
  }

  PlayMode get _mode => _deck.state.canSwitch && _deck.state.vocalLevel < 0.5
      ? PlayMode.karaoke
      : PlayMode.listen;

  Future<void> _finishPlay() async {
    final id = _playId;
    if (id == null) return;
    _playId = null;
    await _services.history.finishPlay(
      id,
      listened: _listened.elapsed,
      mode: _mode,
    );
  }

  Future<void> _saveSession() async {
    final song = state.song;
    if (song == null) return;
    try {
      await _services.appState.saveSession({
        'songId': '${song.id}',
        'positionMs': '${_deck.position.inMilliseconds}',
        'vocalLevel': '${state.engine.vocalLevel}',
      });
    } catch (error) {
      _log.w('Session save failed', error);
    }
  }

  @override
  Future<void> play() async {
    if (state.song == null) return;
    await _focus?.activate();
    await _deck.play();
  }

  @override
  Future<void> pause() async {
    if (state.song == null) return;
    await _deck.pause();
  }

  Future<void> togglePlay() => state.engine.playing ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    if (state.song == null) return;
    await _deck.seek(position);
  }

  Future<void> seekRelative(Duration delta) => seek(_deck.position + delta);

  @override
  Future<void> stop() async {
    await _saveSession();
    await _finishPlay();
    _sessionTimer?.cancel();
    await _deck.stop();
    state = const NowPlaying();
    _handler?.publish(null, EnginePlayerState.idle);
  }

  /// Original ↔ instrumental, keeping the position (150 ms crossfade).
  Future<void> setInstrumental(bool instrumental) async {
    final song = state.song;
    if (song == null || !state.engine.canSwitch) return;
    await _deck.switchTrack(instrumental: instrumental);
    final mode = instrumental ? PlayMode.karaoke : PlayMode.listen;
    await _services.library.setLastMode(song.id, mode.name);
  }

  /// Vocal-guide blend (0 = instrumental only, 1 = original vocals).
  Future<void> setVocalLevel(double level) async {
    if (!state.engine.canSwitch) return;
    await _deck.setVocalLevel(level);
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    await _deck.setVolume(_volume);
  }

  /// Manual line stepping for untimed lyrics (tap, ↑/↓).
  void stepLine(int delta) => setManualLine(state.manualLine + delta);

  void setManualLine(int index) {
    final count = state.lyrics?.lines.length ?? 0;
    if (count == 0) return;
    state = state.copyWith(manualLine: index.clamp(0, count - 1));
  }

  /// Shifts timed lyrics against the audio (positive = lyrics earlier),
  /// ±5 s; stored with the song's current lyric version.
  Future<void> setLyricsOffset(int offsetMs) async {
    final song = state.song;
    final lyrics = state.lyrics;
    if (song == null || lyrics == null) return;
    final saved = await _services.lyrics.setOffset(song.id, offsetMs);
    state = state.copyWith(lyrics: () => lyrics.copyWith(offsetMs: saved));
  }

  /// Playback speed (the sync editor slows the song while timing).
  Future<void> setTempo(double rate) async {
    if (state.song == null) return;
    await _deck.setTempo(rate);
  }

  /// Reloads the current song's lyrics after an import or edit.
  Future<void> reloadLyrics() async {
    final song = state.song;
    if (song == null) return;
    final lyrics = await _services.library.lyrics(song.id);
    state = state.copyWith(lyrics: () => lyrics, manualLine: 0);
  }
}
