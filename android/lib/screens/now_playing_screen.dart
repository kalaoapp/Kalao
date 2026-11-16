import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_import_sheet.dart';
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/services/custom_font_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/lyrics_timeline.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/ruby_lyric_line.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Now playing (M1.13, M2): layered lyrics, transport, seek, original ↔
/// instrumental and the vocal-guide blend. Timed lyrics follow the engine
/// clock with a karaoke sweep over the active line; untimed lyrics are
/// stepped by hand (tap a line, ↑/↓, or the line buttons).
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(playerProvider);
    final song = now.song;
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): controller.togglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            controller.stepLine(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            controller.stepLine(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            controller.seekRelative(const Duration(seconds: -5)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            controller.seekRelative(const Duration(seconds: 5)),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (song.artist.isNotEmpty)
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            actions: [
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
            child: Column(
              children: [
                Expanded(
                  child: now.lyrics == null || now.lyrics!.isEmpty
                      ? _NoLyrics(
                          onImport: () =>
                              showLyricsImportSheet(context, ref, song),
                        )
                      : LyricsView(lyrics: now.lyrics!),
                ),
                const PlayerControls(),
              ],
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

/// The lyric lines. For timed lyrics a ticker follows the interpolated engine
/// position: it picks the active line and drives the sweep across it (word
/// by word with word timing, linearly without). Otherwise the manual line is
/// highlighted. The active line is kept near the top third, without
/// animation when the system asks for reduced motion.
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
    super.dispose();
  }

  void _tick(Duration _) {
    final lyrics = widget.lyrics;
    final position = ref.read(playerProvider.notifier).position;
    final active = lyrics.activeLineAt(position);
    if (active != null) {
      _swept.value = sweptChars(
        lyrics.lines[active],
        position.inMilliseconds + lyrics.offsetMs,
        nextStartMs: nextLeadStartMs(lyrics.lines, active),
      );
    }
    if (active != _active) {
      setState(() => _active = active);
      _reveal(active);
    }
  }

  void _reveal(int? index) {
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[index]?.currentContext;
      if (context == null || !mounted) return;
      final reduced = MediaQuery.disableAnimationsOf(this.context);
      Scrollable.ensureVisible(
        context,
        alignment: 0.35,
        duration: reduced ? Duration.zero : AppTokens.motionMedium,
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final manual = ref.watch(playerProvider.select((now) => now.manualLine));
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
    final layer = settings.showPinyin ? LyricLayerKind.pinyin : null;
    final lines = widget.lyrics.lines;
    final controller = ref.read(playerProvider.notifier);
    return ListView.builder(
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
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.space4),
                    child: RubyLyricLine(
                      line: line,
                      style: style,
                      layer: layer,
                      textAlign: align,
                      swept: sweeping ? _swept : null,
                      sweepColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              if (line.translation != null)
                Text(
                  line.translation!,
                  textAlign: align,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

/// Seek bar, transport, track switch and vocal-guide blend.
class PlayerControls extends ConsumerStatefulWidget {
  const PlayerControls({super.key});

  @override
  ConsumerState<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends ConsumerState<PlayerControls> {
  double? _dragging;
  double? _vocalDrag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final engine = now.engine;
    final duration = engine.duration ?? now.song?.duration ?? Duration.zero;
    final total = duration.inMilliseconds.toDouble();
    final position = _dragging ?? engine.positionMs.clamp(0, total).toDouble();
    final theme = Theme.of(context);
    final untimed =
        now.lyrics != null && !now.lyrics!.timed && !now.lyrics!.isEmpty;
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
                controller.seek(Duration(milliseconds: value.round()));
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space16,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(Duration(milliseconds: position.round())),
                  ),
                  Text(formatDuration(duration)),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (untimed)
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
                  tooltip: engine.playing ? l10n.playerPause : l10n.playerPlay,
                  icon: Icon(engine.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: controller.togglePlay,
                ),
                const SizedBox(width: AppTokens.space8),
                IconButton(
                  tooltip: l10n.playerForward10,
                  icon: const Icon(Icons.forward_10),
                  onPressed: () =>
                      controller.seekRelative(const Duration(seconds: 10)),
                ),
                if (untimed)
                  IconButton(
                    tooltip: l10n.lyricsNextLine,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => controller.stepLine(1),
                  ),
              ],
            ),
            if (engine.canSwitch) ...[
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
                    icon: const Icon(Icons.mic_external_on_outlined),
                    label: Text(l10n.playerInstrumental),
                  ),
                ],
                selected: {now.isInstrumental},
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
                      value: _vocalDrag ?? engine.vocalLevel,
                      divisions: 20,
                      label:
                          '${((_vocalDrag ?? engine.vocalLevel) * 100).round()}%',
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
            if (engine.error != null)
              Text(
                engine.error!,
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

/// Whether a custom font file still exists (used by settings).
bool customFontExists(String? path) => path != null && File(path).existsSync();
