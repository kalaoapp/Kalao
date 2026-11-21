import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/screens/import_sheet.dart';
import 'package:kalao/screens/song_detail_screen.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Opens Now playing for [song], starting it unless it is already current.
Future<void> openSong(
  BuildContext context,
  WidgetRef ref,
  Song song, {
  Duration start = Duration.zero,
}) async {
  final player = ref.read(playerProvider);
  if (player.song?.id != song.id) {
    await ref.read(playerProvider.notifier).playSong(song, start: start);
    // A stream that could not start leaves the previous song playing; the
    // shell shows why.
    if (ref.read(playerProvider).song?.id != song.id) return;
  }
  if (context.mounted) await context.push('/player');
}

/// Home: search, Continue singing, Recently played, Recently added.
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final added = ref.watch(recentlyAddedProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navHome),
        actions: [
          IconButton(
            tooltip: l10n.statsTitle,
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => context.push('/stats'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'import-home',
        onPressed: () => pickAndImport(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.importAction),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space16,
              0,
              AppTokens.space16,
              AppTokens.space8,
            ),
            child: SearchBar(
              controller: _search,
              hintText: l10n.searchHint,
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: l10n.searchClear,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                  ),
              ],
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          if (_query.isNotEmpty)
            _SearchResults(query: _query)
          else if (added.asData?.value.isEmpty ?? false)
            EmptyState(
              icon: Icons.mic_none,
              title: l10n.homeEmptyTitle,
              body: l10n.homeEmptyBody,
            )
          else ...[
            const _ContinueSinging(),
            _Shelf(
              title: l10n.homeRecentlyPlayed,
              songs: ref.watch(recentlyPlayedProvider),
            ),
            _Shelf(title: l10n.homeRecentlyAdded, songs: added),
          ],
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final results = ref.watch(librarySearchProvider(query));
    return switch (results) {
      AsyncData(:final value) => Column(
        children: [
          if (value.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppTokens.space24),
              child: Text(l10n.searchNoResults, textAlign: TextAlign.center),
            ),
          for (final song in value)
            SongListTile(
              song: song,
              onTap: () => openSong(context, ref, song),
              onLongPress: () => showAddToQueueSheet(context, ref, song),
            ),
          if (ref.watch(extensionsProvider).has(ExtensionCapability.metadata))
            _OnlineResults(query: query),
        ],
      ),
      AsyncError(:final error) => Padding(
        padding: const EdgeInsets.all(AppTokens.space16),
        child: Text('$error'),
      ),
      _ => const Padding(
        padding: EdgeInsets.all(AppTokens.space16),
        child: LinearProgressIndicator(),
      ),
    };
  }
}

final _onlineSearchProvider = FutureProvider.autoDispose
    .family<
      ({List<TrackResult> tracks, List<ExtensionFailure> errors}),
      String
    >(
      (ref, query) => ref
          .watch(extensionServiceProvider)
          .searchTracks(TrackQuery(title: query)),
    );

/// Search across the metadata extensions (FEATURES 6.2), after a pause in
/// typing. Results open the track page: play, add or download.
class _OnlineResults extends ConsumerStatefulWidget {
  const _OnlineResults({required this.query});

  final String query;

  @override
  ConsumerState<_OnlineResults> createState() => _OnlineResultsState();
}

class _OnlineResultsState extends ConsumerState<_OnlineResults> {
  Timer? _debounce;
  String? _settled;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_OnlineResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _settled = widget.query);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final query = _settled;
    final results = query == null || query.length < 2
        ? null
        : ref.watch(_onlineSearchProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            AppTokens.space16,
            AppTokens.space16,
            AppTokens.space4,
          ),
          child: Semantics(
            header: true,
            child: Text(
              l10n.searchOnline,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        switch (results) {
          null || AsyncLoading() => const Padding(
            padding: EdgeInsets.all(AppTokens.space16),
            child: LinearProgressIndicator(),
          ),
          AsyncData(:final value) when value.tracks.isEmpty => Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Text(l10n.searchNoResults),
          ),
          AsyncData(:final value) => Column(
            children: [
              for (final track in value.tracks)
                TrackTile(
                  track: track,
                  onTap: () => context.push('/track', extra: track),
                ),
            ],
          ),
          AsyncError(:final error) => Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Text('$error'),
          ),
        },
      ],
    );
  }
}

class _ContinueSinging extends ConsumerWidget {
  const _ContinueSinging();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final resume = ref.watch(continueSingingProvider).asData?.value;
    final current = ref.watch(playerProvider.select((now) => now.song?.id));
    if (resume == null || current == resume.song.id) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space8,
      ),
      child: Card(
        color: theme.colorScheme.secondaryContainer,
        child: ListTile(
          leading: SongCover(song: resume.song),
          title: Text(l10n.homeContinueSinging),
          subtitle: Text(
            '${resume.song.title} · ${formatDuration(resume.position)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.play_arrow),
          onTap: () =>
              openSong(context, ref, resume.song, start: resume.position),
        ),
      ),
    );
  }
}

class _Shelf extends ConsumerWidget {
  const _Shelf({required this.title, required this.songs});

  final String title;
  final AsyncValue<List<Song>> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = songs.asData?.value ?? const <Song>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space16,
            AppTokens.space16,
            AppTokens.space16,
            AppTokens.space8,
          ),
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.space12),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppTokens.space4),
            itemBuilder: (context, index) => SongCard(
              song: list[index],
              onTap: () => openSong(context, ref, list[index]),
              onLongPress: () => showAddToQueueSheet(context, ref, list[index]),
            ),
          ),
        ),
      ],
    );
  }
}
