import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// The current song above the navigation bar; tap opens Now playing. Only
/// the progress bar follows the position.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final (song, playing) = ref.watch(
      playerProvider.select((now) => (now.song, now.engine.playing)),
    );
    if (song == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push('/player'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _MiniProgress(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
                vertical: AppTokens.space8,
              ),
              child: Row(
                children: [
                  SongCover(song: song, size: 40),
                  const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (song.artist.isNotEmpty)
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: playing ? l10n.playerPause : l10n.playerPlay,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () =>
                        ref.read(playerProvider.notifier).togglePlay(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      playerProvider.select((now) {
        final duration = now.engine.duration ?? now.song?.duration;
        if (duration == null || duration.inMilliseconds == 0) return 0.0;
        return (now.engine.positionMs / duration.inMilliseconds).clamp(
          0.0,
          1.0,
        );
      }),
    );
    return LinearProgressIndicator(value: progress, minHeight: 2);
  }
}
