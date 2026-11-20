import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_import_sheet.dart';
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/screens/shortcuts_sheet.dart';
import 'package:kalao/services/custom_font_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/lyrics_timeline.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/karaoke_lyrics_view.dart';
import 'package:kalao/widgets/lyric_line_view.dart';
import 'package:kalao/widgets/screen_awake.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Now playing: Learn mode (scrolling layered lyrics, loop a line, A–B
/// repeat, slow-down, line stepping) or Karaoke mode (large two-line layout
/// with the sweep and countdown, screen kept on), with transport, seek,
/// original ↔ instrumental and the vocal-guide blend. Keyboard and gamepad
/// shortcuts are listed in the help sheet (`?`).
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // The engine reports 30 times a second; the layout only depends on these.
    final (:song, :lyrics, :singer, :karaoke, :playing) = ref.watch(
      playerProvider.select(
        (now) => (
          song: now.song,
          lyrics: now.lyrics,
          singer: now.singer,
          karaoke: now.isKaraoke,
          playing: now.engine.playing,
        ),
      ),
    );
    if (song == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.music_off_outlined,
          title: l10n.playerNothingPlaying,
          body: l10n.playerNothingPlayingBody,
        ),
      );
    }
    final controller = ref.read(playerProvider.notifier);
    final keepOn = ref.watch(settingsProvider.select((s) => s.keepScreenOn));
    void back5() => controller.seekRelative(const Duration(seconds: -5));
    void forward5() => controller.seekRelative(const Duration(seconds: 5));
    void switchTrack() =>
        controller.setInstrumental(!ref.read(playerProvider).isInstrumental);
    final karaokeLayout = karaoke && lyrics != null && lyrics.timed;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): controller.togglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            controller.stepLine(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            controller.stepLine(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): back5,
        const SingleActivator(LogicalKeyboardKey.arrowRight): forward5,
        const SingleActivator(LogicalKeyboardKey.keyS): switchTrack,
        const SingleActivator(LogicalKeyboardKey.keyL):
            controller.toggleLineLoop,
        const CharacterActivator('?'): () => showShortcutsSheet(context),
        // Gamepad: the D-pad arrives as arrow keys.
        const SingleActivator(LogicalKeyboardKey.gameButtonA):
            controller.togglePlay,
        const SingleActivator(LogicalKeyboardKey.gameButtonX): switchTrack,
        const SingleActivator(LogicalKeyboardKey.gameButtonY):
            controller.toggleLineLoop,
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): back5,
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1): forward5,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (song.artist.isNotEmpty || singer.isNotEmpty)
                  Text(
                    [
                      if (singer.isNotEmpty) singer,
                      if (song.artist.isNotEmpty) song.artist,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            actions: [
              _FavoriteButton(songId: song.id),
              IconButton(
                tooltip: l10n.queueAdd,
                icon: const Icon(Icons.playlist_add),
                onPressed: () => showAddToQueueSheet(context, ref, song),
              ),
              IconButton(
                tooltip: l10n.lyricsImport,
                icon: const Icon(Icons.edit_note),
                onPressed: () => showLyricsImportSheet(context, ref, song),
              ),
              IconButton(
                tooltip: l10n.lyricsOptions,
                icon: const Icon(Icons.tune),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => const LyricsOptionsSheet(),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final lyricsPane = lyrics == null || lyrics.isEmpty
                    ? _NoLyrics(
                        onImport: () =>
                            showLyricsImportSheet(context, ref, song),
                      )
                    : karaokeLayout
                    ? KaraokeLyricsView(lyrics: lyrics)
                    : LyricsView(lyrics: lyrics);
                final awake = ScreenAwake(
                  enabled: karaoke && playing && keepOn,
                );
                // Landscape: stacked controls would take most of the short
                // height, so they move to a scrolling side panel and the
                // lyrics keep the full height.
                if (constraints.maxWidth > constraints.maxHeight) {
                  return Row(
                    children: [
                      awake,
                      Expanded(child: lyricsPane),
                      Container(
                        width: (constraints.maxWidth * 0.4).clamp(280, 400),
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        alignment: Alignment.center,
                        child: const SingleChildScrollView(
                          child: PlayerControls(),
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    awake,
                    Expanded(child: lyricsPane),
                    const PlayerControls(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NoLyrics extends ConsumerWidget {
  const _NoLyrics({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final song = ref.watch(playerProvider.select((now) => now.song));
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: AppTokens.space24),
          if (song != null)
            SongCover(song: song, size: 200, radius: AppTokens.radiusLarge),
          EmptyState(
            icon: Icons.lyrics_outlined,
            title: l10n.lyricsNone,
            body: l10n.lyricsNoneBody,
          ),
          FilledButton.tonalIcon(
            onPressed: onImport,
            icon: const Icon(Icons.add),
            label: Text(l10n.lyricsImport),
          ),
        ],
      ),
    );
  }
}

/// The scrolling lyric lines (Learn mode, and any untimed lyrics). For timed
/// lyrics a ticker follows the interpolated engine position: it picks the
/// active line and drives the sweep across it (word by word with word
/// timing, linearly without). Otherwise the manual line is highlighted. The
/// active line is kept near the top third, without animation when the system
/// asks for reduced motion, and re-centred when the layout changes (rotation,
/// lyric size). Tap a line to play from it (or highlight it); long-press a
/// line to repeat it, then another to repeat everything between the two.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, required this.lyrics});

  final LyricDocument lyrics;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _keys = <int, GlobalKey>{};
  final _scroll = ScrollController();

  /// What the line positions depend on; a change re-centres the active line.
  Object? _layout;

  /// UTF-16 units of the active line sung so far; only the sweep's clip
  /// listens, so a frame repaints one line instead of rebuilding the list.
  final _swept = ValueNotifier<double>(0);
  int? _active;

  @override
  void initState() {
    super.initState();
    if (widget.lyrics.timed) _ticker.start();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (widget.lyrics.timed && !_ticker.isActive) _ticker.start();
    if (!widget.lyrics.timed && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _swept.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    final lyrics = widget.lyrics;
    final position = ref.read(playerProvider.notifier).position();
    final active = lyrics.activeLineAt(position);
    if (active != null) {
      _swept.value = sweptChars(
        lyrics.lines[active],
        position.inMilliseconds + lyrics.offsetMs,
        nextStartMs: nextLeadStartMs(lyrics.lines, active),
      );
    }
    if (active != _active) {
      // The first line found (opening, rotation) jumps into place.
      final animate = _active != null;
      setState(() => _active = active);
      _reveal(active, animate: animate);
    }
  }

  void _reveal(int? index, {bool animate = true, int attempt = 0}) {
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _keys[index]?.currentContext;
      if (target == null) {
        // The list only builds lines near the viewport: jump to where the
        // line should be, then align it once it is built.
        if (attempt >= 3) return;
        final position = _scroll.position;
        final last = math.max(1, widget.lyrics.lines.length - 1);
        position.jumpTo(
          (position.maxScrollExtent * index / last).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
        _reveal(index, animate: false, attempt: attempt + 1);
        return;
      }
      final reduced = MediaQuery.disableAnimationsOf(context);
      Scrollable.ensureVisible(
        target,
        alignment: 0.35,
        duration: animate && !reduced ? AppTokens.motionMedium : Duration.zero,
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final manual = ref.watch(playerProvider.select((now) => now.manualLine));
    final loopLines = ref.watch(playerProvider.select((now) => now.loopLines));
    final font = ref.watch(customFontFamilyProvider).asData?.value;
    final active = widget.lyrics.timed ? _active : manual;
    ref.listen(playerProvider.select((now) => now.manualLine), (_, next) {
      if (!widget.lyrics.timed) _reveal(next);
    });
    final theme = Theme.of(context);
    final base = theme.textTheme.headlineSmall!.copyWith(
      fontSize: 22 * settings.lyricsSize.scale,
      fontFamily: font,
      height: 1.3,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = (constraints.biggest, settings, font);
        if (_layout != null && _layout != layout) {
          _reveal(active, animate: false);
        }
        _layout = layout;
        return _buildList(context, settings, active, loopLines, base);
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    AppSettings settings,
    int? active,
    (int, int)? loopLines,
    TextStyle base,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lines = widget.lyrics.lines;
    final controller = ref.read(playerProvider.notifier);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space24,
        vertical: AppTokens.space32,
      ),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final isActive = index == active;
        // Backing vocals light up with the lead line they follow.
        final highlighted =
            isActive ||
            (line.isBacking &&
                active != null &&
                index > active &&
                lines
                    .getRange(active + 1, index)
                    .every((between) => between.isBacking));
        final sweeping = isActive && widget.lyrics.timed && settings.wordSweep;
        final style = base.copyWith(
          fontSize: line.isBacking ? base.fontSize! * 0.8 : null,
          fontStyle: line.isBacking ? FontStyle.italic : null,
          fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
          color: sweeping
              ? theme.colorScheme.onSurface
              : highlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        );
        // Duet sides: the first voice on the left, the others on the right.
        final align = switch (line.voice) {
          null || backingVoice => TextAlign.center,
          'v1' => TextAlign.start,
          _ => TextAlign.end,
        };
        return Padding(
          key: _keys.putIfAbsent(index, GlobalKey.new),
          padding: EdgeInsets.only(
            top: line.sectionBreakBefore ? AppTokens.space24 : AppTokens.space8,
            bottom: AppTokens.space8,
          ),
          child: Column(
            crossAxisAlignment: switch (align) {
              TextAlign.start => CrossAxisAlignment.start,
              TextAlign.end => CrossAxisAlignment.end,
              _ => CrossAxisAlignment.center,
            },
            children: [
              if (line.section != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.space4),
                  child: Text(
                    sectionLabel(l10n, line.section!),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ),
              Semantics(
                button: true,
                selected: isActive,
                onTapHint: widget.lyrics.timed
                    ? l10n.lyricsSeekHere
                    : l10n.lyricsSelectLine,
                onLongPressHint: widget.lyrics.timed ? l10n.learnLoop : null,
                child: Material(
                  // The repeated lines stay marked while the loop is on.
                  color:
                      loopLines != null &&
                          index >= loopLines.$1 &&
                          index <= loopLines.$2
                      ? theme.colorScheme.tertiaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSmall),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppTokens.radiusSmall),
                    onTap: () {
                      if (widget.lyrics.timed) {
                        controller.seek(
                          line.time -
                              Duration(milliseconds: widget.lyrics.offsetMs),
                        );
                      } else {
                        controller.setManualLine(index);
                      }
                    },
                    onLongPress: widget.lyrics.timed
                        ? () => controller.holdLine(index)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(AppTokens.space4),
                      child: LyricLineView(
                        line: line,
                        style: style,
                        settings: settings,
                        textAlign: align,
                        swept: sweeping ? _swept : null,
                        sweepColor: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String sectionLabel(AppLocalizations l10n, String section) => switch (section) {
  'verse' => l10n.sectionVerse,
  'preChorus' => l10n.sectionPreChorus,
  'chorus' => l10n.sectionChorus,
  'postChorus' => l10n.sectionPostChorus,
  'bridge' => l10n.sectionBridge,
  'intro' => l10n.sectionIntro,
  'outro' => l10n.sectionOutro,
  'interlude' => l10n.sectionInterlude,
  _ => l10n.sectionOther,
};

/// Mode, seek bar, transport, Learn tools, track switch and vocal-guide
/// blend.
class PlayerControls extends ConsumerStatefulWidget {
  const PlayerControls({super.key});

  @override
  ConsumerState<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends ConsumerState<PlayerControls> {
  /// Slow-down presets of Learn mode (IMPLEMENTATION.md §5).
  static const _tempos = [0.5, 0.75, 0.9, 1.0];

  double? _vocalDrag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Everything but the position, which only the seek bar follows.
    final now = ref.watch(
      playerProvider.select(
        (now) => (
          mode: now.mode,
          karaoke: now.isKaraoke,
          instrumental: now.isInstrumental,
          lyrics: now.lyrics,
          loopLines: now.loopLines,
          loopOpen: now.loopOpen,
          playing: now.engine.playing,
          looping: now.engine.looping,
          tempo: now.engine.tempo,
          canSwitch: now.engine.canSwitch,
          vocalLevel: now.engine.vocalLevel,
          error: now.engine.error,
        ),
      ),
    );
    final controller = ref.read(playerProvider.notifier);
    final theme = Theme.of(context);
    final lyrics = now.lyrics;
    final hasLyrics = lyrics != null && !lyrics.isEmpty;
    final learn = !now.karaoke;
    final repeating = now.looping || now.loopLines != null;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space16,
          AppTokens.space8,
          AppTokens.space16,
          AppTokens.space12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PlayModeButton(mode: now.mode, onChanged: controller.setMode),
            const SeekBar(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (hasLyrics && learn)
                  IconButton(
                    tooltip: l10n.lyricsPreviousLine,
                    icon: const Icon(Icons.keyboard_arrow_up),
                    onPressed: () => controller.stepLine(-1),
                  ),
                IconButton(
                  tooltip: l10n.playerBack10,
                  icon: const Icon(Icons.replay_10),
                  onPressed: () =>
                      controller.seekRelative(const Duration(seconds: -10)),
                ),
                const SizedBox(width: AppTokens.space8),
                IconButton.filled(
                  iconSize: 40,
                  tooltip: now.playing ? l10n.playerPause : l10n.playerPlay,
                  icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: controller.togglePlay,
                ),
                const SizedBox(width: AppTokens.space8),
                IconButton(
                  tooltip: l10n.playerForward10,
                  icon: const Icon(Icons.forward_10),
                  onPressed: () =>
                      controller.seekRelative(const Duration(seconds: 10)),
                ),
                if (hasLyrics && learn)
                  IconButton(
                    tooltip: l10n.lyricsNextLine,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => controller.stepLine(1),
                  ),
              ],
            ),
            if (learn && hasLyrics && lyrics.timed)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Long-pressing a line starts a repeat; this ends it.
                    if (repeating)
                      Padding(
                        padding: const EdgeInsets.only(right: AppTokens.space8),
                        child: ActionChip(
                          avatar: const Icon(Icons.repeat_one_on),
                          label: Text(l10n.learnLoopOff),
                          onPressed: controller.clearLoop,
                        ),
                      ),
                    for (final (i, tempo) in _tempos.indexed)
                      Padding(
                        padding: EdgeInsets.only(
                          left: i == 0 ? 0 : AppTokens.space8,
                        ),
                        child: ChoiceChip(
                          label: Text('${(tempo * 100).round()}%'),
                          tooltip: l10n.learnSpeed((tempo * 100).round()),
                          selected: now.tempo == tempo,
                          onSelected: (_) => controller.setTempo(tempo),
                        ),
                      ),
                  ],
                ),
              ),
            if (now.loopOpen)
              Text(
                l10n.learnAbPick,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            if (now.canSwitch) ...[
              const SizedBox(height: AppTokens.space8),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: Text(l10n.playerOriginal),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.music_note_outlined),
                    label: Text(l10n.playerInstrumental),
                  ),
                ],
                selected: {now.instrumental},
                onSelectionChanged: (selection) =>
                    controller.setInstrumental(selection.first),
              ),
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: AppTokens.space8),
                    child: Text(
                      l10n.playerVocalGuide,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _vocalDrag ?? now.vocalLevel,
                      divisions: 20,
                      label:
                          '${((_vocalDrag ?? now.vocalLevel) * 100).round()}%',
                      semanticFormatterCallback: (value) =>
                          '${l10n.playerVocalGuide} ${(value * 100).round()}%',
                      onChanged: (value) {
                        setState(() => _vocalDrag = value);
                        unawaited(controller.setVocalLevel(value));
                      },
                      onChangeEnd: (_) => setState(() => _vocalDrag = null),
                    ),
                  ),
                ],
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.space4),
                child: Text(
                  l10n.playerNoInstrumental,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (now.error case final error?)
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The seek slider and times: the only part of the controls that follows
/// the position.
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key});

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (positionMs, duration) = ref.watch(
      playerProvider.select(
        (now) => (
          now.engine.positionMs,
          now.engine.duration ?? now.song?.duration ?? Duration.zero,
        ),
      ),
    );
    final total = duration.inMilliseconds.toDouble();
    final position = _dragging ?? positionMs.clamp(0, total).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(
          value: total <= 0 ? 0 : position.clamp(0, total),
          max: total <= 0 ? 1 : total,
          semanticFormatterCallback: (value) =>
              '${l10n.playerSeek} ${formatDuration(Duration(milliseconds: value.round()))}',
          onChanged: total <= 0
              ? null
              : (value) => setState(() => _dragging = value),
          onChangeEnd: (value) {
            setState(() => _dragging = null);
            ref
                .read(playerProvider.notifier)
                .seek(Duration(milliseconds: value.round()));
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.space16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDuration(Duration(milliseconds: position.round()))),
              Text(formatDuration(duration)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Heart toggle for the current song.
class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton({required this.songId});

  final int songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final favorite = ref.watch(favoriteProvider(songId)).asData?.value ?? false;
    return IconButton(
      tooltip: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      isSelected: favorite,
      icon: const Icon(Icons.favorite_border),
      selectedIcon: const Icon(Icons.favorite),
      onPressed: () => setFavorite(ref, songId, !favorite),
    );
  }
}
