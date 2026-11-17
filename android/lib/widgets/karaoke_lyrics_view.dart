import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/custom_font_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/lyrics_timeline.dart';
import 'package:kalao/widgets/lyric_line_view.dart';

/// A gap before the next line at least this long gets a countdown.
const countdownGapMs = 4000;

/// What the Karaoke view shows at one moment.
@immutable
class KaraokeFrame {
  const KaraokeFrame({this.current, this.next, this.dots, this.ended = false});

  /// The line being sung, or null in a gap.
  final int? current;

  /// The line that comes after [current] (or after the gap).
  final int? next;

  /// In a long gap: countdown dots left before [next] starts (1–4), or 0
  /// while it is further away. Null outside a long gap.
  final int? dots;

  /// The last line is over.
  final bool ended;

  /// The frame for [doc] at song position [positionMs] (offset not applied).
  static KaraokeFrame at(LyricDocument doc, int positionMs) {
    final ms = positionMs + doc.offsetMs;
    final lines = doc.lines;
    final active = doc.activeLineAt(Duration(milliseconds: positionMs));
    int? next;
    for (var index = (active ?? -1) + 1; index < lines.length; index++) {
      if (!lines[index].isBacking) {
        next = index;
        break;
      }
    }
    final nextStart = next == null ? null : lines[next].time.inMilliseconds;
    // The gap runs from the end of the active line (or the song start).
    final gapStart = active == null
        ? 0
        : lineEndMs(lines[active], nextStartMs: nextStart);
    final inGap = ms >= gapStart;
    if (next == null) {
      return KaraokeFrame(current: inGap ? null : active, ended: inGap);
    }
    if (!inGap || nextStart! - gapStart < countdownGapMs) {
      return KaraokeFrame(current: active, next: next);
    }
    final until = nextStart - ms;
    return KaraokeFrame(
      next: next,
      dots: until > countdownGapMs ? 0 : (until / 1000).ceil().clamp(1, 4),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KaraokeFrame &&
      other.current == current &&
      other.next == next &&
      other.dots == dots &&
      other.ended == ended;

  @override
  int get hashCode => Object.hash(current, next, dots, ended);
}

/// OG Karaoke layout (IMPLEMENTATION.md §5): the line being sung in large
/// type with the sweep, the next line under it, countdown dots before a line
/// that follows a gap of four seconds or more (the intro included), and the
/// next singer from the queue once the lyrics are over.
class KaraokeLyricsView extends ConsumerStatefulWidget {
  const KaraokeLyricsView({super.key, required this.lyrics});

  final LyricDocument lyrics;

  @override
  ConsumerState<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

class _KaraokeLyricsViewState extends ConsumerState<KaraokeLyricsView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _swept = ValueNotifier<double>(0);
  KaraokeFrame _frame = const KaraokeFrame();

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _swept.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    final lyrics = widget.lyrics;
    final position = ref.read(playerProvider.notifier).position();
    final frame = KaraokeFrame.at(lyrics, position.inMilliseconds);
    final current = frame.current;
    if (current != null) {
      _swept.value = sweptChars(
        lyrics.lines[current],
        position.inMilliseconds + lyrics.offsetMs,
        nextStartMs: nextLeadStartMs(lyrics.lines, current),
      );
    }
    if (frame != _frame) setState(() => _frame = frame);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final font = ref.watch(customFontFamilyProvider).asData?.value;
    final lines = widget.lyrics.lines;
    final frame = _frame;
    final large = theme.textTheme.headlineMedium!.copyWith(
      fontSize: 34 * settings.lyricsSize.scale,
      fontFamily: font,
      fontWeight: FontWeight.w700,
      height: 1.25,
    );
    final upcoming = large.copyWith(
      fontSize: large.fontSize! * 0.7,
      fontWeight: FontWeight.w500,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final current = frame.current;
    final next = frame.next;
    final dots = frame.dots;
    final showDots = dots != null && settings.countdown;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space24),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The row keeps its height so lines do not jump when the
              // countdown appears.
              SizedBox(
                height: 36,
                child: showDots
                    ? Semantics(
                        liveRegion: true,
                        label: dots == 0
                            ? l10n.karaokeInterlude
                            : l10n.karaokeCountdown(dots),
                        child: ExcludeSemantics(
                          child: dots == 0
                              ? Icon(
                                  Icons.music_note,
                                  color: theme.colorScheme.onSurfaceVariant,
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (var dot = 0; dot < dots; dot++)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppTokens.space4,
                                        ),
                                        child: Icon(
                                          Icons.circle,
                                          size: 16,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: AppTokens.space12),
              if (current != null)
                LyricLineView(
                  key: ValueKey('karaoke-current-$current'),
                  line: lines[current],
                  settings: settings,
                  style: large.copyWith(
                    color: settings.wordSweep
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.primary,
                  ),
                  swept: settings.wordSweep ? _swept : null,
                  sweepColor: theme.colorScheme.primary,
                ),
              if (next != null) ...[
                const SizedBox(height: AppTokens.space24),
                LyricLineView(
                  key: ValueKey('karaoke-next-$next'),
                  line: lines[next],
                  settings: settings,
                  // After a gap the upcoming line is the main one.
                  style: current == null
                      ? large.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : upcoming,
                ),
              ],
              if (frame.ended) const _NextSinger(),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Next: singer — song" from the head of the queue, after the last line.
class _NextSinger extends ConsumerWidget {
  const _NextSinger();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final next = ref.watch(queueProvider).asData?.value.firstOrNull;
    if (next == null) {
      return Icon(
        Icons.music_note,
        size: 48,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    final singer = next.item.singer;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.karaokeNextUp, style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.space4),
            if (singer.isNotEmpty)
              Text(singer, style: theme.textTheme.headlineSmall),
            Text(
              next.song.title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
