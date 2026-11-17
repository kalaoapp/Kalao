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
import 'package:kalao/screens/shortcuts_sheet.dart';
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
    final engine = ref.watch(playerProvider.select((now) => now.engine));
    final japanese = hasLyrics && lyrics.sourceLang == 'ja';
    final chinese = hasLyrics && lyrics.sourceLang == 'zh';
    final translated =
        hasLyrics && lyrics.lines.any((line) => line.translation != null);
    final semitones = engine.key.round();
    final percent = (engine.tempo * 100).round();
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (song != null) ...[
              StepperTile(
                icon: Icons.music_note_outlined,
                title: l10n.soundKey,
                value: semitones == 0
                    ? l10n.soundKeyOriginal
                    : l10n.soundKeySemitones(
                        semitones > 0 ? '+$semitones' : '−${-semitones}',
                      ),
                resetTooltip: l10n.soundKeyReset,
                onReset: semitones == 0 ? null : () => player.setKey(0),
                decreaseTooltip: l10n.soundKeyDown,
                increaseTooltip: l10n.soundKeyUp,
                onDecrease: semitones <= -6
                    ? null
                    : () => player.setKey(semitones - 1),
                onIncrease: semitones >= 6
                    ? null
                    : () => player.setKey(semitones + 1),
              ),
              StepperTile(
                icon: Icons.speed,
                title: l10n.soundTempo,
                value: '$percent%',
                resetTooltip: l10n.soundTempoReset,
                onReset: percent == 100 ? null : () => player.setTempo(1),
                decreaseTooltip: l10n.soundTempoSlower,
                increaseTooltip: l10n.soundTempoFaster,
                onDecrease: percent <= 50
                    ? null
                    : () => player.setTempo((percent - 5) / 100),
                onIncrease: percent >= 150
                    ? null
                    : () => player.setTempo((percent + 5) / 100),
              ),
              const Divider(),
            ],
            if (!japanese)
              SwitchListTile(
                secondary: const Icon(Icons.translate),
                title: Text(l10n.lyricsShowPinyin),
                value: settings.showPinyin,
                onChanged: notifier.setShowPinyin,
              ),
            if (japanese) ...[
              SwitchListTile(
                secondary: const Icon(Icons.translate),
                title: Text(l10n.lyricsShowFurigana),
                value: settings.showFurigana,
                onChanged: notifier.setShowFurigana,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.abc),
                title: Text(l10n.lyricsShowRomaji),
                value: settings.showRomaji,
                onChanged: notifier.setShowRomaji,
              ),
            ],
            if (chinese || !hasLyrics) const ChineseVariantTile(),
            if (translated)
              SwitchListTile(
                secondary: const Icon(Icons.subtitles_outlined),
                title: Text(l10n.lyricsShowTranslation),
                value: settings.showTranslation,
                onChanged: notifier.setShowTranslation,
              ),
            SwitchListTile(
              secondary: const Icon(Icons.gradient),
              title: Text(l10n.lyricsSweep),
              subtitle: Text(l10n.lyricsSweepSubtitle),
              value: settings.wordSweep,
              onChanged: notifier.setWordSweep,
            ),
            const LyricsSizeTile(),
            SwitchListTile(
              secondary: const Icon(Icons.more_horiz),
              title: Text(l10n.karaokeCountdownSetting),
              subtitle: Text(l10n.karaokeCountdownSettingSubtitle),
              value: settings.countdown,
              onChanged: notifier.setCountdown,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.lightbulb_outline),
              title: Text(l10n.karaokeKeepScreenOn),
              value: settings.keepScreenOn,
              onChanged: notifier.setKeepScreenOn,
            ),
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
            ListTile(
              leading: const Icon(Icons.keyboard_outlined),
              title: Text(l10n.shortcutsTitle),
              onTap: () {
                Navigator.pop(context);
                showShortcutsSheet(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// How Chinese lyrics are written: as imported, or converted for display.
class ChineseVariantTile extends ConsumerWidget {
  const ChineseVariantTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final variant = ref.watch(settingsProvider.select((s) => s.chineseVariant));
    String label(ChineseVariant value) => switch (value) {
      ChineseVariant.asWritten => l10n.chineseAsWritten,
      ChineseVariant.simplified => l10n.chineseSimplified,
      ChineseVariant.traditional => l10n.chineseTraditional,
      ChineseVariant.taiwan => l10n.chineseTaiwan,
      ChineseVariant.hongKong => l10n.chineseHongKong,
    };
    return ListTile(
      leading: const Icon(Icons.g_translate),
      title: Text(l10n.chineseVariant),
      trailing: DropdownButton<ChineseVariant>(
        value: variant,
        underline: const SizedBox.shrink(),
        items: [
          for (final value in ChineseVariant.values)
            DropdownMenuItem(value: value, child: Text(label(value))),
        ],
        onChanged: (value) {
          if (value != null) {
            ref.read(settingsProvider.notifier).setChineseVariant(value);
          }
        },
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
