import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/player_state.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/playback_handler.dart';
import 'package:kalao/utils/logger.dart';
import 'package:kalao/utils/lyrics_timeline.dart';

const _log = AppLogger('Player');

/// Injected in `main` after `AudioService.init`; null in tests.
final audioHandlerProvider = Provider<KalaoAudioHandler?>((ref) => null);

/// Whether the player requests audio focus; overridden to true in `main`.
final audioFocusEnabledProvider = Provider<bool>((ref) => false);

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
    this.mode = PlayMode.learn,
    this.singer = '',
    this.loopLines,
    this.loopOpen = false,
  });

  final Song? song;
  final LyricDocument? lyrics;
  final EnginePlayerState engine;

  /// The highlighted line when stepping manually through untimed lyrics.
  final int manualLine;

  /// Learn (original vocals, study tools) or Karaoke (backing track, big
  /// lyrics). `listen` only appears in history from before modes existed.
  final PlayMode mode;

  /// Who is singing (from the queue); empty when nobody was named.
  final String singer;

  /// The first and last lyric line being repeated, or null.
  final (int, int)? loopLines;

  /// A long-pressed line is repeating and the next long-press on another
  /// line widens the repeat to everything between the two.
  final bool loopOpen;

  bool get isInstrumental => engine.canSwitch && engine.vocalLevel < 0.5;
  bool get isKaraoke => mode == PlayMode.karaoke;

  NowPlaying copyWith({
    Song? song,
    LyricDocument? Function()? lyrics,
    EnginePlayerState? engine,
    int? manualLine,
    PlayMode? mode,
    (int, int)? Function()? loopLines,
    bool? loopOpen,
  }) => NowPlaying(
    song: song ?? this.song,
    lyrics: lyrics != null ? lyrics() : this.lyrics,
    engine: engine ?? this.engine,
    manualLine: manualLine ?? this.manualLine,
    mode: mode ?? this.mode,
    singer: singer,
    loopLines: loopLines != null ? loopLines() : this.loopLines,
    loopOpen: loopOpen ?? this.loopOpen,
  );
}

final playerProvider = NotifierProvider<PlayerController, NowPlaying>(
  PlayerController.new,
);

/// Plays library songs on the engine, keeps history and the session for
/// "Continue singing", drives the media session and moves through the queue
/// (Mornye's music_player_service + playback_session_restore roles, sized
/// for one deck).
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
    // Audio focus does not depend on the media session: without focus,
    // another app's audio plays over Kalao's. Tests have no handler and no
    // audio session plugin.
    final focus = ref.watch(audioFocusEnabledProvider)
        ? AudioFocus(
            this,
            isPlaying: () => state.engine.playing,
            setDucked: (ducked) =>
                _deck.setVolume(ducked ? _volume * 0.3 : _volume),
          )
        : null;
    _focus = focus;
    unawaited(focus?.start());
    ref.listen(
      settingsProvider.select((settings) => settings.chineseVariant),
      (_, _) => unawaited(_applyVariant()),
    );
    ref.onDispose(() {
      _states?.cancel();
      _sessionTimer?.cancel();
      focus?.dispose();
    });
    return const NowPlaying();
  }

  LibraryServices get _services => ref.read(libraryServicesProvider);

  void _onEngine(EnginePlayerState engine) {
    final before = state.engine;
    state = state.copyWith(engine: engine);
    if (engine.playing && !_listened.isRunning) _listened.start();
    if (!engine.playing && _listened.isRunning) _listened.stop();
    if (before.playing && !engine.playing) unawaited(_saveSession());
    _handler?.publish(state.song, engine);
    if (engine.completed && !before.completed) unawaited(playNextInQueue());
  }

  /// Interpolated engine position for lyric display.
  Duration position() => _deck.position;

  /// The files to load for [song]: original + instrumental when both exist,
  /// otherwise whichever exists.
  static Map<String, String> sourcesFor(Song song) => {
    for (final file in song.media) file.kind.name: file.path,
  };

  /// The mode a song opens in: the one last used for it, else Learn.
  static PlayMode modeFor(Song song) => song.lastMode == PlayMode.karaoke.name
      ? PlayMode.karaoke
      : PlayMode.learn;

  /// Loads [song] (at [start]) and starts playing in [mode] (default: the
  /// mode last used for the song). Karaoke plays the backing track when the
  /// song has one.
  Future<void> playSong(
    Song song, {
    Duration start = Duration.zero,
    PlayMode? mode,
    String singer = '',
  }) async {
    await _finishPlay();
    final sources = sourcesFor(song);
    if (sources.isEmpty) return;
    final playMode = mode ?? modeFor(song);
    final lyrics = await _loadLyrics(song.id);
    state = NowPlaying(
      song: song,
      lyrics: lyrics,
      engine: state.engine,
      mode: playMode,
      singer: singer,
    );
    await _deck.load(songId: '${song.id}', sources: sources, start: start);
    // Speed, key and loops belong to one play of one song.
    if (_deck.state.tempo != 1) await _deck.setTempo(1);
    if (_deck.state.key != 0) await _deck.setKey(0);
    if (song.hasBacking) {
      await _deck.switchTrack(instrumental: playMode == PlayMode.karaoke);
    } else {
      await _deck.setVocalLevel(1);
    }
    await play();
    _playId = await _services.history.startPlay(
      songId: song.id,
      songKey: song.songKey.isNotEmpty
          ? song.songKey
          : LibraryDatabase.songKey(
              song.title,
              song.artist,
              song.durationMs,
              null,
            ),
      mode: playMode,
      singer: singer,
    );
    _listened.reset();
    // Before the bump, so "Continue singing" never re-reads the previous song.
    await _saveSession();
    ref.read(libraryRevisionProvider.notifier).bump();
    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (state.engine.playing) unawaited(_saveSession());
    });
  }

  /// The song's current lyrics in the Chinese variant from settings.
  Future<LyricDocument?> _loadLyrics(int songId) async {
    final lyrics = await _services.library.lyrics(songId);
    if (lyrics == null) return null;
    try {
      return await _services.lyrics.withVariant(
        lyrics,
        ref.read(settingsProvider).chineseVariant,
      );
    } catch (error) {
      _log.w('Chinese variant conversion failed', error);
      return lyrics;
    }
  }

  Future<void> _applyVariant() async {
    final song = state.song;
    if (song == null) return;
    final lyrics = await _loadLyrics(song.id);
    if (state.song?.id == song.id) {
      state = state.copyWith(lyrics: () => lyrics);
    }
  }

  Future<void> _finishPlay() async {
    final id = _playId;
    if (id == null) return;
    _playId = null;
    await _services.history.finishPlay(
      id,
      listened: _listened.elapsed,
      mode: state.mode,
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
      ref.invalidate(continueSingingProvider);
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

  /// Plays the first song in the queue (when a song ends, or on request).
  /// Returns false when the queue is empty.
  Future<bool> playNextInQueue() async {
    while (true) {
      final item = await _services.queue.takeFirst();
      if (item == null) return false;
      final song = await _services.library.song(item.songId);
      // The song may have been deleted since it was queued.
      if (song == null) continue;
      await playSong(song, mode: item.mode, singer: item.singer);
      return true;
    }
  }

  /// Learn ↔ Karaoke for this play; remembered for the song.
  Future<void> setMode(PlayMode mode) async {
    final song = state.song;
    if (song == null || mode == state.mode) return;
    state = state.copyWith(mode: mode);
    if (state.engine.canSwitch) {
      await _deck.switchTrack(instrumental: mode == PlayMode.karaoke);
    }
    await _services.library.setLastMode(song.id, mode.name);
  }

  /// Original ↔ instrumental, keeping the position (150 ms crossfade).
  Future<void> setInstrumental(bool instrumental) async {
    if (state.song == null || !state.engine.canSwitch) return;
    await _deck.switchTrack(instrumental: instrumental);
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

  /// Playback speed 0.5–1.5 at the same pitch.
  Future<void> setTempo(double rate) async {
    if (state.song == null) return;
    await _deck.setTempo(rate);
  }

  /// Transposition in semitones, ±6.
  Future<void> setKey(double semitones) async {
    if (state.song == null) return;
    await _deck.setKey(semitones);
  }

  /// The song-time range of lines [first]..[last] of the timed lyrics.
  (Duration, Duration)? _lineRange(int first, int last) {
    final lyrics = state.lyrics;
    if (lyrics == null || !lyrics.timed) return null;
    if (first < 0 || last >= lyrics.lines.length || first > last) return null;
    final start = lyrics.lines[first].time.inMilliseconds - lyrics.offsetMs;
    final end =
        lineEndMs(
          lyrics.lines[last],
          nextStartMs: nextLeadStartMs(lyrics.lines, last),
        ) -
        lyrics.offsetMs;
    final from = start < 0 ? 0 : start;
    // The engine refuses loops shorter than a quarter of a second.
    final to = end < from + 300 ? from + 300 : end;
    return (Duration(milliseconds: from), Duration(milliseconds: to));
  }

  /// Repeats lines [first]..[last] from the start of [first].
  Future<void> _repeatLines(int first, int last, {required bool open}) async {
    final range = _lineRange(first, last);
    if (range == null) return;
    state = state.copyWith(loopLines: () => (first, last), loopOpen: open);
    await _deck.setLoop(start: range.$1, end: range.$2);
    await _deck.seek(range.$1);
  }

  /// Repeats the line being sung, or stops repeating (shortcuts).
  Future<void> toggleLineLoop() async {
    if (state.loopLines != null || state.engine.looping) return clearLoop();
    final active = state.lyrics?.activeLineAt(_deck.position);
    if (active == null) return;
    await _repeatLines(active, active, open: false);
  }

  /// Long-press on line [index] (Learn mode): repeats that line. A
  /// long-press on another line next repeats everything between the two; a
  /// long-press on a repeated line stops.
  Future<void> holdLine(int index) async {
    final lines = state.loopLines;
    if (lines != null && state.loopOpen && index != lines.$1) {
      final anchor = lines.$1;
      return _repeatLines(
        anchor < index ? anchor : index,
        anchor < index ? index : anchor,
        open: false,
      );
    }
    if (lines != null && index >= lines.$1 && index <= lines.$2) {
      return clearLoop();
    }
    await _repeatLines(index, index, open: true);
  }

  Future<void> clearLoop() async {
    state = state.copyWith(loopLines: () => null, loopOpen: false);
    if (state.engine.looping) await _deck.setLoop();
  }

  /// Line stepping (↑/↓, buttons): timed lyrics jump to the previous or next
  /// line; untimed lyrics move the highlighted line.
  Future<void> stepLine(int delta) async {
    final lyrics = state.lyrics;
    if (lyrics == null || lyrics.isEmpty) return;
    if (!lyrics.timed) return setManualLine(state.manualLine + delta);
    var index = (lyrics.activeLineAt(_deck.position) ?? -1) + delta;
    while (index >= 0 &&
        index < lyrics.lines.length &&
        lyrics.lines[index].isBacking) {
      index += delta.sign;
    }
    if (index < 0 || index >= lyrics.lines.length) return;
    final ms = lyrics.lines[index].time.inMilliseconds - lyrics.offsetMs;
    await seek(Duration(milliseconds: ms < 0 ? 0 : ms));
  }

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

  /// Reloads the current song's lyrics after an import or edit.
  Future<void> reloadLyrics() async {
    final song = state.song;
    if (song == null) return;
    final lyrics = await _loadLyrics(song.id);
    state = state.copyWith(lyrics: () => lyrics, manualLine: 0);
  }
}
