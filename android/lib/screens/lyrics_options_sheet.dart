import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/logger.dart';
import 'package:kalao/widgets/stepper_tile.dart';

const _log = AppLogger('Lyrics');

/// Saves [doc] as an `.lrc` file (`lrc` = line timing, `elrc` = enhanced LRC
/// with word timing) where the user chooses. Returns whether a file was
/// written; reports the result in a snack bar.
Future<bool> exportLyricsFile(
  BuildContext context,
  WidgetRef ref,
  Song song,
  LyricDocument doc,
  String format,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final text = await ref
        .read(libraryServicesProvider)
        .lyrics
        .exportText(doc, format, title: song.title, artist: song.artist);
    final name = [
      if (song.artist.isNotEmpty) song.artist,
      song.title,
    ].join(' - ').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final saved = await FilePicker.saveFile(
      fileName: '$name.lrc',
      bytes: utf8.encode(text),
      mimeType: 'text/plain',
    );
    if (saved == null) return false;
    messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsExported)));
    return true;
  } catch (error) {
    _log.w('Lyrics export failed', error);
    messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsExportFailed)));
    return false;
  }
}

/// `+0.15 s` / `−0.30 s` / `0.00 s`.
String formatOffset(int offsetMs) {
  final sign = offsetMs > 0
      ? '+'
      : offsetMs < 0
      ? '−'
      : '';
  return '$sign${(offsetMs.abs() / 1000).toStringAsFixed(2)} s';
}

/// Layer toggles, lyric size, and for the playing song: the karaoke sweep,
/// the timing offset, the sync editor and LRC export (Mornye's lyrics
/// options sheet, reduced).
class LyricsOptionsSheet extends ConsumerWidget {
  const LyricsOptionsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final song = ref.watch(playerProvider.select((now) => now.song));
    final lyrics = ref.watch(playerProvider.select((now) => now.lyrics));
    final hasLyrics = song != null && lyrics != null && !lyrics.isEmpty;
    final timed = hasLyrics && lyrics.timed;
    final player = ref.read(playerProvider.notifier);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.translate),
              title: Text(l10n.lyricsShowPinyin),
              value: settings.showPinyin,
              onChanged: notifier.setShowPinyin,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.gradient),
              title: Text(l10n.lyricsSweep),
              subtitle: Text(l10n.lyricsSweepSubtitle),
              value: settings.wordSweep,
              onChanged: notifier.setWordSweep,
            ),
            const LyricsSizeTile(),
            if (timed)
              StepperTile(
                icon: Icons.timer_outlined,
                title: l10n.lyricsOffset,
                value: formatOffset(lyrics.offsetMs),
                resetTooltip: l10n.lyricsOffsetReset,
                onReset: lyrics.offsetMs == 0
                    ? null
                    : () => player.setLyricsOffset(0),
                decreaseTooltip: l10n.lyricsOffsetLater,
                increaseTooltip: l10n.lyricsOffsetEarlier,
                onDecrease: lyrics.offsetMs <= -LyricDocument.maxOffsetMs
                    ? null
                    : () => player.setLyricsOffset(
                        lyrics.offsetMs - LyricDocument.offsetStepMs,
                      ),
                onIncrease: lyrics.offsetMs >= LyricDocument.maxOffsetMs
                    ? null
                    : () => player.setLyricsOffset(
                        lyrics.offsetMs + LyricDocument.offsetStepMs,
                      ),
              ),
            if (hasLyrics)
              ListTile(
                leading: const Icon(Icons.touch_app_outlined),
                title: Text(l10n.lyricsSync),
                subtitle: Text(l10n.lyricsSyncSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  context.push('/player/sync');
                },
              ),
            if (timed) ...[
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l10n.lyricsExportLrc),
                onTap: () =>
                    exportLyricsFile(context, ref, song, lyrics, 'lrc'),
              ),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l10n.lyricsExportElrc),
                onTap: () =>
                    exportLyricsFile(context, ref, song, lyrics, 'elrc'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lyric size S–XXL, shared by the options sheet and appearance settings.
class LyricsSizeTile extends ConsumerWidget {
  const LyricsSizeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final size = ref.watch(settingsProvider.select((s) => s.lyricsSize));
    return ListTile(
      leading: const Icon(Icons.format_size),
      title: Text(l10n.settingsLyricsSize),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: AppTokens.space8),
        child: SegmentedButton<LyricsSize>(
          showSelectedIcon: false,
          segments: [
            for (final value in LyricsSize.values)
              ButtonSegment(
                value: value,
                label: Text(value.name.toUpperCase()),
              ),
          ],
          selected: {size},
          onSelectionChanged: (selection) => ref
              .read(settingsProvider.notifier)
              .setLyricsSize(selection.first),
        ),
      ),
    );
  }
}
