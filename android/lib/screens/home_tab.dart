import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/screens/song_detail_screen.dart';
import 'package:kalao/services/library_database.dart';
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

/// Home, with the library in it: search (library matches first, then the
/// extensions'), stats, Continue singing, Recently played, Recently added
/// and every song, as a list or a grid, with sort, favourites and a
/// selection mode (long press).
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  final _search = TextEditingController();
  String _query = '';
  SongSort _sort = SongSort.recentlyAdded;
  bool _grid = false;
  bool _favoritesOnly = false;
  final _selected = <int>{};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(Song song) => setState(() {
    if (!_selected.remove(song.id)) _selected.add(song.id);
  });

  void _open(Song song) {
    if (_selecting) {
      _toggle(song);
    } else {
      openSong(context, ref, song);
    }
  }

  Future<void> _deleteSelected(List<Song> songs) async {
    final l10n = AppLocalizations.of(context);
    final chosen = songs.where((song) => _selected.contains(song.id)).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.libraryDeleteTitle(chosen.length)),
        content: Text(l10n.libraryDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final player = ref.read(playerProvider);
    if (chosen.any((song) => song.id == player.song?.id)) {
      await ref.read(playerProvider.notifier).stop();
    }
    final services = ref.read(libraryServicesProvider);
    await services.importer.deleteSongs(chosen);
    await services.history.forgetSongs([for (final song in chosen) song.id]);
    await services.queue.removeSongs([for (final song in chosen) song.id]);
    final session = await services.appState.session();
    if (chosen.any((song) => '${song.id}' == session['songId'])) {
      await services.appState.clearSession();
    }
    setState(_selected.clear);
    ref.read(libraryRevisionProvider.notifier).bump();
  }

  /// Queues the selected songs in list order, for Karaoke, no singer named.
  Future<void> _queueSelected(List<Song> songs) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(queueActionsProvider);
    final chosen = [
      for (final song in songs)
        if (_selected.contains(song.id)) song,
    ];
    setState(_selected.clear);
    for (final song in chosen) {
      await actions.add(song);
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.queueAdded)));
  }

  Future<void> _favoriteSelected() async {
    final library = ref.read(libraryServicesProvider).library;
    final chosen = [..._selected];
    setState(_selected.clear);
    for (final id in chosen) {
      await library.setFavorite(id, true);
    }
    ref.read(libraryRevisionProvider.notifier).bump();
  }

  PreferredSizeWidget _selectionBar(List<Song> songs) {
    final l10n = AppLocalizations.of(context);
    return AppBar(
      leading: IconButton(
        tooltip: l10n.actionCancel,
        icon: const Icon(Icons.close),
        onPressed: () => setState(_selected.clear),
      ),
      title: Text(l10n.librarySelected(_selected.length)),
      actions: [
        IconButton(
          tooltip: l10n.librarySelectAll,
          icon: const Icon(Icons.select_all),
          onPressed: () =>
              setState(() => _selected.addAll(songs.map((s) => s.id))),
        ),
        IconButton(
          tooltip: l10n.queueAdd,
          icon: const Icon(Icons.playlist_add),
          onPressed: () => _queueSelected(songs),
        ),
        IconButton(
          tooltip: l10n.favoriteAdd,
          icon: const Icon(Icons.favorite_border),
          onPressed: _favoriteSelected,
        ),
        IconButton(
          tooltip: l10n.actionDelete,
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _deleteSelected(songs),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final added = ref.watch(recentlyAddedProvider);
    final songs = ref.watch(
      librarySongsProvider((sort: _sort, favoritesOnly: _favoritesOnly)),
    );
    final list = songs.asData?.value ?? const <Song>[];
    final libraryEmpty = added.asData?.value.isEmpty ?? false;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting
            ? _selectionBar(list)
            : AppBar(
                title: Text(l10n.navHome),
                actions: [
                  IconButton(
                    tooltip: l10n.statsTitle,
                    icon: const Icon(Icons.insights_outlined),
                    onPressed: () => context.push('/stats'),
                  ),
                ],
              ),
        body: CustomScrollView(
          slivers: [
            if (!_selecting)
              SliverToBoxAdapter(
                child: Padding(
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
              ),
            if (_query.isNotEmpty && !_selecting)
              SliverToBoxAdapter(child: _SearchResults(query: _query))
            else if (libraryEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.mic_none,
                  title: l10n.homeEmptyTitle,
                  body: l10n.homeEmptyBody,
                ),
              )
            else ...[
              if (!_selecting) ...[
                const SliverToBoxAdapter(child: _ContinueSinging()),
                SliverToBoxAdapter(
                  child: _Shelf(
                    title: l10n.homeRecentlyPlayed,
                    songs: ref.watch(recentlyPlayedProvider),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _Shelf(title: l10n.homeRecentlyAdded, songs: added),
                ),
              ],
              SliverToBoxAdapter(child: _libraryHeader(l10n)),
              ..._librarySlivers(l10n, songs),
            ],
            const SliverToBoxAdapter(
              child: SizedBox(height: AppTokens.space24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _libraryHeader(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space16,
      AppTokens.space16,
      AppTokens.space4,
      0,
    ),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              l10n.navLibrary,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          tooltip: l10n.libraryFavoritesOnly,
          isSelected: _favoritesOnly,
          icon: const Icon(Icons.favorite_border),
          selectedIcon: const Icon(Icons.favorite),
          onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
        ),
        PopupMenuButton<SongSort>(
          tooltip: l10n.librarySort,
          icon: const Icon(Icons.sort),
          initialValue: _sort,
          onSelected: (sort) => setState(() => _sort = sort),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: SongSort.recentlyAdded,
              child: Text(l10n.sortRecentlyAdded),
            ),
            PopupMenuItem(value: SongSort.title, child: Text(l10n.sortTitle)),
            PopupMenuItem(value: SongSort.artist, child: Text(l10n.sortArtist)),
          ],
        ),
        IconButton(
          tooltip: _grid ? l10n.libraryShowList : l10n.libraryShowGrid,
          icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
          onPressed: () => setState(() => _grid = !_grid),
        ),
      ],
    ),
  );

  List<Widget> _librarySlivers(
    AppLocalizations l10n,
    AsyncValue<List<Song>> songs,
  ) => switch (songs) {
    AsyncData(:final value) when value.isEmpty && _favoritesOnly => [
      SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.favorite_border,
          title: l10n.favoritesEmptyTitle,
          body: l10n.favoritesEmptyBody,
        ),
      ),
    ],
    AsyncData(:final value) when value.isEmpty => [
      SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.library_music_outlined,
          title: l10n.libraryEmptyTitle,
          body: l10n.libraryEmptyBody,
        ),
      ),
    ],
    AsyncError(:final error) => [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.space16),
          child: Text('$error'),
        ),
      ),
    ],
    AsyncData(:final value) when _grid => [
      SliverPadding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space12,
          vertical: AppTokens.space8,
        ),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.72,
          ),
          itemCount: value.length,
          itemBuilder: (context, index) {
            final song = value[index];
            return LayoutBuilder(
              builder: (context, constraints) => SongCard(
                song: song,
                width: constraints.maxWidth - AppTokens.space8,
                selected: _selected.contains(song.id),
                onTap: () => _open(song),
                onLongPress: () => _toggle(song),
              ),
            );
          },
        ),
      ),
    ],
    AsyncData(:final value) => [
      SliverList.builder(
        itemCount: value.length,
        itemBuilder: (context, index) {
          final song = value[index];
          return SongListTile(
            song: song,
            selectionMode: _selecting,
            selected: _selected.contains(song.id),
            onTap: () => _open(song),
            onLongPress: () => _toggle(song),
          );
        },
      ),
    ],
    _ => [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(AppTokens.space24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    ],
  };
}

/// Library matches first, best first; none when nothing in the library is
/// a likely match. Then the extensions' results.
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final results = ref.watch(homeSearchProvider(query));
    final online = ref
        .watch(extensionsProvider)
        .has(ExtensionCapability.metadata);
    return switch (results) {
      AsyncData(:final value) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (value.isNotEmpty) ...[
            _SectionTitle(l10n.navLibrary),
            for (final song in value)
              SongListTile(
                song: song,
                onTap: () => openSong(context, ref, song),
                onLongPress: () => showAddToQueueSheet(context, ref, song),
              ),
          ],
          _LyricsResults(query: query, shown: {for (final s in value) s.id}),
          if (online)
            _OnlineResults(query: query)
          else if (value.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppTokens.space24),
              child: Text(l10n.searchNoResults, textAlign: TextAlign.center),
            ),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space16,
      AppTokens.space16,
      AppTokens.space16,
      AppTokens.space4,
    ),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

/// Songs whose lyrics have the query (FEATURES 6.12), less those [shown]
/// above already.
class _LyricsResults extends ConsumerWidget {
  const _LyricsResults({required this.query, required this.shown});

  final String query;
  final Set<int> shown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = [
      for (final song
          in ref.watch(lyricsSearchProvider(query)).asData?.value ??
              const <Song>[])
        if (!shown.contains(song.id)) song,
    ];
    if (songs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(AppLocalizations.of(context).searchInLyrics),
        for (final song in songs)
          SongListTile(
            song: song,
            onTap: () => openSong(context, ref, song),
            onLongPress: () => showAddToQueueSheet(context, ref, song),
          ),
      ],
    );
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
        _SectionTitle(l10n.searchOnline),
        switch (results) {
          null || AsyncLoading() => const Padding(
            padding: EdgeInsets.all(AppTokens.space16),
            child: LinearProgressIndicator(),
          ),
          AsyncData(:final value) when value.tracks.isEmpty => Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Text(l10n.searchNoResults),
          ),
          AsyncData(:final value) => Builder(
            builder: (context) {
              String key(TrackResult track) => LibraryDatabase.songKey(
                track.title,
                track.artist,
                track.durationMs,
                track.isrc,
              );
              // "In Library" by ISRC or song key (FEATURES 6.12).
              final known =
                  ref
                      .watch(
                        knownSongKeysProvider(value.tracks.map(key).join('\n')),
                      )
                      .asData
                      ?.value ??
                  const <String>{};
              return Column(
                children: [
                  for (final track in value.tracks)
                    TrackTile(
                      track: track,
                      trailing: known.contains(key(track))
                          ? Chip(label: Text(l10n.inLibrary))
                          : null,
                      onTap: () => context.push('/track', extra: track),
                    ),
                ],
              );
            },
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
