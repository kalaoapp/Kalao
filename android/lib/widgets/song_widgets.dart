import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Cover art from app storage, or a tinted placeholder.
class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.song, this.size = 48, this.radius});

  final Song song;
  final double size;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = song.coverPath;
    final placeholder = ColoredBox(
      color: scheme.primaryContainer,
      child: Icon(
        Icons.music_note,
        color: scheme.onPrimaryContainer,
        size: size * 0.5,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? AppTokens.radiusSmall),
      child: SizedBox.square(
        dimension: size,
        child: path == null
            ? placeholder
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

String formatDuration(Duration? duration) {
  if (duration == null) return '–:––';
  final minutes = duration.inMinutes;
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Small badges: has instrumental, has lyrics.
class SongBadges extends StatelessWidget {
  const SongBadges({super.key, required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (song.unavailable)
          Tooltip(
            message: l10n.songUnavailable,
            child: Icon(
              Icons.cloud_off_outlined,
              size: 16,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (song.hasBacking)
          Tooltip(
            message: l10n.songHasInstrumental,
            child: Icon(Icons.mic_external_on_outlined, size: 16, color: color),
          ),
        if (song.hasLyrics)
          Tooltip(
            message: l10n.songHasLyrics,
            child: Icon(Icons.lyrics_outlined, size: 16, color: color),
          ),
      ],
    );
  }
}

class SongListTile extends StatelessWidget {
  const SongListTile({
    super.key,
    required this.song,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.trailing,
  });

  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;

  /// Replaces the badges (a playlist's drag handle).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (song.artist.isNotEmpty) song.artist,
      formatDuration(song.duration),
    ].join(' · ');
    final tile = ListTile(
      leading: selectionMode
          ? Checkbox(value: selected, onChanged: (_) => onTap?.call())
          : SongCover(song: song),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? SongBadges(song: song),
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    // A song whose file is gone or offline is shown dimmed (FEATURES 6.9).
    return song.unavailable && !selectionMode
        ? Opacity(opacity: 0.55, child: tile)
        : tile;
  }
}

/// A square card for grids and horizontal shelves.
class SongCard extends StatelessWidget {
  const SongCard({
    super.key,
    required this.song,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.width = 140,
  });

  final Song song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: [song.title, if (song.artist.isNotEmpty) song.artist].join(', '),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.space4),
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    SongCover(
                      song: song,
                      size: width - AppTokens.space8,
                      radius: AppTokens.radiusMedium,
                    ),
                    if (selected)
                      Positioned(
                        top: AppTokens.space4,
                        right: AppTokens.space4,
                        child: Icon(
                          Icons.check_circle,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppTokens.space4),
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
