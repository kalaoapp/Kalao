import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/settings_group.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// The stats and the songs they name.
typedef StatsView = ({PlayStats stats, Map<int, Song> songs});

final playStatsProvider = FutureProvider<StatsView>((ref) async {
  ref.watch(libraryRevisionProvider);
  final services = ref.watch(libraryServicesProvider);
  final stats = await services.history.stats();
  final ids = {
    for (final list in [stats.topSongs, stats.mostPractised, stats.bestScores])
      for (final entry in list) entry.songId,
  };
  final songs = await services.library.songsByIds([...ids]);
  return (stats: stats, songs: {for (final song in songs) song.id: song});
});

/// Stats (FEATURES 6.7): local only, from the `play` history.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final view = ref.watch(playStatsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.statsTitle)),
      body: switch (view) {
        AsyncData(:final value) when value.stats.plays == 0 => EmptyState(
          icon: Icons.insights_outlined,
          title: l10n.statsEmptyTitle,
          body: l10n.statsEmptyBody,
        ),
        AsyncData(:final value) => _StatsBody(view: value),
        AsyncError(:final error) => Center(child: Text('$error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.view});

  final StatsView view;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stats = view.stats;
    Widget songRows(List<SongStat> entries, String Function(num) label) =>
        Column(
          children: [
            for (final entry in entries)
              if (view.songs[entry.songId] case final song?)
                ListTile(
                  leading: SongCover(song: song, size: 40),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: song.artist.isEmpty ? null : Text(song.artist),
                  trailing: Text(label(entry.value)),
                ),
          ],
        );
    return ListView(
      padding: const EdgeInsets.only(bottom: AppTokens.space24),
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTokens.space16),
          child: Row(
            children: [
              _Total(label: l10n.statsPlays, value: '${stats.plays}'),
              _Total(
                label: l10n.statsTimeSung,
                value: formatListenTime(stats.timeSung),
              ),
              _Total(label: l10n.statsSongs, value: '${stats.songs}'),
            ],
          ),
        ),
        SettingsGroup(
          title: l10n.statsLastWeek,
          children: [_DayBars(days: stats.days)],
        ),
        if (stats.topSongs.isNotEmpty)
          SettingsGroup(
            title: l10n.statsTopSongs,
            children: [
              songRows(stats.topSongs, (v) => l10n.statsPlayCount(v.toInt())),
            ],
          ),
        if (stats.mostPractised.isNotEmpty)
          SettingsGroup(
            title: l10n.statsMostPractised,
            children: [
              songRows(
                stats.mostPractised,
                (v) => formatListenTime(Duration(milliseconds: v.toInt())),
              ),
            ],
          ),
        if (stats.bestScores.isNotEmpty)
          SettingsGroup(
            title: l10n.statsBestScores,
            children: [songRows(stats.bestScores, (v) => '${v.round()}')],
          ),
      ],
    );
  }
}

/// "1 h 5 min", "12 min" or "40 s".
String formatListenTime(Duration time) {
  if (time.inHours > 0) return '${time.inHours} h ${time.inMinutes % 60} min';
  if (time.inMinutes > 0) return '${time.inMinutes} min';
  return '${time.inSeconds} s';
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Semantics(
        container: true,
        child: Column(
          children: [
            Text(value, style: theme.textTheme.headlineSmall),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minutes sung per day, as bars scaled to the busiest day.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.days});

  final List<({DateTime day, int plays, int ms})> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final weekday = DateFormat.E(locale);
    final most = days.fold<int>(1, (max, d) => d.ms > max ? d.ms : max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space8,
        AppTokens.space16,
        AppTokens.space16,
      ),
      child: SizedBox(
        height: 120,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final day in days)
              Expanded(
                child: Semantics(
                  label:
                      '${DateFormat.MMMEd(locale).format(day.day)}: '
                      '${formatListenTime(Duration(milliseconds: day.ms))}',
                  excludeSemantics: true,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: AppTokens.space4,
                        ),
                        height: 4 + 80 * day.ms / most,
                        decoration: BoxDecoration(
                          color: day.ms == 0
                              ? theme.colorScheme.surfaceContainerHighest
                              : theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: AppTokens.space4),
                      Text(
                        weekday.format(day.day),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
