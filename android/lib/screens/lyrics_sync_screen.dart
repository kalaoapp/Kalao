import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/controllers/lyrics_sync_editor_controller.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/lyrics_options_sheet.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/stepper_tile.dart';

/// `01:02.34`, or dashes for a line that is not timed yet.
String formatLyricTime(int? ms) {
  if (ms == null) return '--:--.--';
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = (ms ~/ 1000 % 60).toString().padLeft(2, '0');
  final hundredths = (ms % 1000 ~/ 10).toString().padLeft(2, '0');
  return '$minutes:$seconds.$hundredths';
}

/// Tap-to-time sync editor (M2.4): play the song, tap at the start of each
/// line (or word); hold to the end to stamp where it ends. The song can be
/// slowed while timing; taps are corrected for tap latency (the engine
/// position already allows for output latency).
class LyricsSyncScreen extends ConsumerStatefulWidget {
  const LyricsSyncScreen({super.key});

  @override
  ConsumerState<LyricsSyncScreen> createState() => _LyricsSyncScreenState();
}

class _LyricsSyncScreenState extends ConsumerState<LyricsSyncScreen> {
  static const _tempos = [0.5, 0.75, 1.0];

  LyricsSyncEditor? _editor;
  late final PlayerController _player = ref.read(playerProvider.notifier);
  final _keys = <int, GlobalKey>{};
  final _held = Stopwatch();
  int _revealed = -1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final lyrics = ref.read(playerProvider).lyrics;
    if (lyrics != null && !lyrics.isEmpty) {
      _editor = LyricsSyncEditor(lyrics)..addListener(_onDraft);
    }
  }

  @override
  void dispose() {
    _editor?.dispose();
    // Timing may have slowed the song down.
    unawaited(_player.setTempo(1));
    super.dispose();
  }

  void _onDraft() {
    final editor = _editor!;
    setState(() {});
    if (editor.cursor != _revealed) {
      _revealed = editor.cursor;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _keys[editor.cursor]?.currentContext;
        if (context == null || !mounted) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.3,
          duration: MediaQuery.disableAnimationsOf(this.context)
              ? Duration.zero
              : AppTokens.motionMedium,
        );
      });
    }
  }

  /// The song position a tap refers to: the finger lands a little after the
  /// sound it reacts to, and that delay covers less song at a slower tempo.
  int _tapPosition() {
    final latency = ref.read(settingsProvider).tapLatencyMs;
    final tempo = ref.read(playerProvider).engine.tempo;
    return _player.position().inMilliseconds - (latency * tempo).round();
  }

  void _down() {
    _held
      ..reset()
      ..start();
    _editor!.tapDown(_tapPosition());
  }

  void _up() {
    _held.stop();
    _editor!.tapUp(_tapPosition(), held: _held.elapsed);
  }

  Future<void> _replay() async {
    final editor = _editor!;
    final index = editor.target?.$1 ?? editor.cursor - 1;
    if (index < 0 || index >= editor.lines.length) return;
    final time = editor.lines[index].timeMs;
    if (time == null) return;
    editor.select(index);
    await _player.seek(Duration(milliseconds: (time - 1500).clamp(0, time)));
    await _player.play();
  }

  Future<void> _save(Song song) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await ref
          .read(libraryServicesProvider)
          .lyrics
          .save(song.id, _editor!.build(), source: 'userEdited');
      ref.read(libraryRevisionProvider.notifier).bump();
      await _player.reloadLyrics();
      messenger.showSnackBar(SnackBar(content: Text(l10n.syncSaved)));
      navigator.pop();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final song = ref.watch(playerProvider.select((now) => now.song));
    final editor = _editor;
    if (song == null || editor == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.syncTitle)),
        body: EmptyState(
          icon: Icons.lyrics_outlined,
          title: l10n.lyricsNone,
          body: l10n.lyricsNoneBody,
        ),
      );
    }
    final complete = editor.complete;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncTitle),
        actions: [
          IconButton(
            tooltip: l10n.syncUndo,
            icon: const Icon(Icons.undo),
            onPressed: editor.canUndo ? editor.undo : null,
          ),
          PopupMenuButton<String>(
            tooltip: l10n.syncExport,
            icon: const Icon(Icons.file_download_outlined),
            enabled: complete,
            onSelected: (format) =>
                exportLyricsFile(context, ref, song, editor.build(), format),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'lrc', child: Text(l10n.lyricsExportLrc)),
              PopupMenuItem(value: 'elrc', child: Text(l10n.lyricsExportElrc)),
            ],
          ),
          TextButton(
            onPressed: complete && !_saving ? () => _save(song) : null,
            child: Text(l10n.actionSave),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _lines(context, editor)),
            _SyncControls(
              editor: editor,
              tempos: _tempos,
              onDown: _down,
              onUp: _up,
              onReplay: _replay,
            ),
          ],
        ),
      ),
    );
  }

  Widget _lines(BuildContext context, LyricsSyncEditor editor) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.labelMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
      itemCount: editor.lines.length,
      itemBuilder: (context, index) {
        final line = editor.lines[index];
        final current = index == editor.cursor;
        final showWords =
            current && editor.mode == SyncMode.word && line.words.isNotEmpty;
        return ListTile(
          key: _keys.putIfAbsent(index, GlobalKey.new),
          selected: current,
          selectedTileColor: theme.colorScheme.primaryContainer,
          selectedColor: theme.colorScheme.onPrimaryContainer,
          leading: Text(formatLyricTime(line.timeMs), style: mono),
          title: showWords
              ? Wrap(
                  spacing: AppTokens.space4,
                  runSpacing: AppTokens.space4,
                  children: [
                    for (final (wordIndex, word) in line.words.indexed)
                      _WordChip(
                        text: line.text.substring(word.start, word.end),
                        timed: word.timeMs != null,
                        next: wordIndex == editor.wordCursor,
                      ),
                  ],
                )
              : Text(line.text),
          subtitle: line.endMs == null
              ? null
              : Text('→ ${formatLyricTime(line.endMs)}', style: mono),
          trailing: line.wordTimed
              ? Icon(
                  Icons.more_horiz,
                  semanticLabel: l10n(context).syncModeWord,
                )
              : null,
          onTap: () => editor.select(index),
        );
      },
    );
  }

  static AppLocalizations l10n(BuildContext context) =>
      AppLocalizations.of(context);
}

class _WordChip extends StatelessWidget {
  const _WordChip({
    required this.text,
    required this.timed,
    required this.next,
  });

  final String text;
  final bool timed;
  final bool next;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: timed ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusSmall),
        border: Border.all(
          color: next ? scheme.primary : scheme.outlineVariant,
          width: next ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space8,
          vertical: AppTokens.space4,
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: timed ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _SyncControls extends ConsumerWidget {
  const _SyncControls({
    required this.editor,
    required this.tempos,
    required this.onDown,
    required this.onUp,
    required this.onReplay,
  });

  final LyricsSyncEditor editor;
  final List<double> tempos;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final engine = ref.watch(playerProvider.select((now) => now.engine));
    final latency = ref.watch(settingsProvider.select((s) => s.tapLatencyMs));
    final settings = ref.read(settingsProvider.notifier);
    final player = ref.read(playerProvider.notifier);
    final tempo = tempos.contains(engine.tempo) ? engine.tempo : 1.0;
    final canNudge = editor.target != null;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<SyncMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: SyncMode.line,
                        label: Text(l10n.syncModeLine),
                      ),
                      ButtonSegment(
                        value: SyncMode.word,
                        label: Text(l10n.syncModeWord),
                      ),
                    ],
                    selected: {editor.mode},
                    onSelectionChanged: (selection) =>
                        editor.setMode(selection.first),
                  ),
                ),
                const SizedBox(width: AppTokens.space8),
                Expanded(
                  child: Semantics(
                    label: l10n.syncTempo,
                    child: SegmentedButton<double>(
                      showSelectedIcon: false,
                      segments: [
                        for (final value in tempos)
                          ButtonSegment(
                            value: value,
                            label: Text('${(value * 100).round()}%'),
                          ),
                      ],
                      selected: {tempo},
                      onSelectionChanged: (selection) =>
                          player.setTempo(selection.first),
                    ),
                  ),
                ),
              ],
            ),
            StepperTile(
              dense: true,
              icon: Icons.touch_app_outlined,
              title: l10n.syncTapLatency,
              value: '$latency ms',
              decreaseTooltip: l10n.syncTapLatencyLess,
              increaseTooltip: l10n.syncTapLatencyMore,
              onDecrease: latency <= 0
                  ? null
                  : () => settings.setTapLatencyMs(latency - 10),
              onIncrease: latency >= 200
                  ? null
                  : () => settings.setTapLatencyMs(latency + 10),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final delta in const [-50, -10, 10, 50])
                  TextButton(
                    onPressed: canNudge ? () => editor.nudge(delta) : null,
                    child: Text(
                      delta > 0 ? '+$delta' : '−${-delta}',
                      semanticsLabel: l10n.syncNudge(delta),
                    ),
                  ),
                IconButton(
                  tooltip: l10n.syncReplay,
                  icon: const Icon(Icons.replay),
                  onPressed: onReplay,
                ),
                IconButton.filledTonal(
                  tooltip: engine.playing ? l10n.playerPause : l10n.playerPlay,
                  icon: Icon(engine.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: player.togglePlay,
                ),
              ],
            ),
            const SizedBox(height: AppTokens.space8),
            // Pointer events, not onTap: the stamp is the moment the finger
            // lands and the end is the moment it lifts.
            Semantics(
              button: true,
              enabled: !editor.finished,
              label: editor.mode == SyncMode.word
                  ? l10n.syncTapWord
                  : l10n.syncTap,
              hint: l10n.syncTapHint,
              onTap: editor.finished
                  ? null
                  : () {
                      onDown();
                      onUp();
                    },
              child: Listener(
                key: const ValueKey('sync-tap'),
                onPointerDown: editor.finished ? null : (_) => onDown(),
                onPointerUp: editor.finished ? null : (_) => onUp(),
                onPointerCancel: editor.finished ? null : (_) => onUp(),
                child: Container(
                  height: 88,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: editor.finished
                        ? theme.colorScheme.surfaceContainerHighest
                        : theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
                  ),
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          editor.finished
                              ? l10n.syncDone
                              : editor.mode == SyncMode.word
                              ? l10n.syncTapWord
                              : l10n.syncTap,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: editor.finished
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.onPrimary,
                          ),
                        ),
                        Text(
                          editor.complete
                              ? l10n.syncTapHint
                              : l10n.syncLinesLeft(editor.remaining),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: editor.finished
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.onPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
