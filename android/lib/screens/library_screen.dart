import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/screens/home_tab.dart';
import 'package:kalao/screens/import_sheet.dart';
import 'package:kalao/screens/library/library_filter_sheet.dart';
import 'package:kalao/screens/library/library_pages.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/library/library_actions.dart';
import 'package:kalao/widgets/library/paged_song_list.dart';

/// Library (FEATURES 6.11): Songs, Albums, Artists, Genres, Folders and
/// Playlists, after Mornye's Library tab. Songs are paged, filtered and
/// sorted; a long press selects them for the queue, a playlist, favorites or
/// deletion. The view shown last is remembered.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  SongQuery _query = const SongQuery();
  bool _grid = false;
  final _selected = <int>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(Song song) => setState(() {
    if (!_selected.remove(song.id)) _selected.add(song.id);
  });

  LibraryTab get _tab =>
      ref.watch(settingsProvider.select((s) => s.libraryTab));

  void _setTab(LibraryTab tab) {
    setState(_selected.clear);
    ref.read(settingsProvider.notifier).setLibraryTab(tab);
  }

  Future<List<Song>> _chosen() =>
      ref.read(libraryServicesProvider).library.songsByIds([..._selected]);

  Future<void> _deleteSelected() async {
    final l10n = AppLocalizations.of(context);
    final chosen = await _chosen();
    if (!mounted) return;
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

  Future<void> _selectAll() async {
    final ids = await ref.read(libraryServicesProvider).browse.ids(_query);
    setState(() => _selected.addAll(ids));
  }

  Future<void> _queueSelected() async {
    final ids = [..._selected];
    setState(_selected.clear);
    await queueAll(context, ref, ids);
  }

  Future<void> _playlistSelected() async {
    final ids = [..._selected];
    setState(_selected.clear);
    await addToPlaylist(context, ref, ids);
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

  void _open(Song song) {
    if (_selecting) {
      _toggle(song);
    } else {
      openSong(context, ref, song);
    }
  }

  Future<void> _filters() async {
    final next = await showLibraryFilters(context, _query);
    if (next != null) setState(() => _query = next);
  }

  PreferredSizeWidget _tabs(AppLocalizations l10n) => PreferredSize(
    preferredSize: const Size.fromHeight(52),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space8,
      ),
      child: Row(
        children: [
          for (final (tab, label) in [
            (LibraryTab.songs, l10n.libraryViewSongs),
            (LibraryTab.albums, l10n.libraryViewAlbums),
            (LibraryTab.artists, l10n.libraryViewArtists),
            (LibraryTab.genres, l10n.libraryViewGenres),
            (LibraryTab.folders, l10n.libraryViewFolders),
            (LibraryTab.playlists, l10n.libraryViewPlaylists),
          ])
            Padding(
              padding: const EdgeInsets.only(right: AppTokens.space8),
              child: ChoiceChip(
                label: Text(label),
                selected: _tab == tab,
                onSelected: (_) => _setTab(tab),
              ),
            ),
        ],
      ),
    ),
  );

  List<Widget> _songActions(AppLocalizations l10n) {
    final filters = _query.activeFilters;
    return [
      IconButton(
        tooltip: l10n.libraryFilters,
        onPressed: _filters,
        icon: Badge(
          isLabelVisible: filters > 0,
          label: Text('$filters'),
          child: const Icon(Icons.filter_list),
        ),
      ),
      PopupMenuButton<LibrarySort>(
        tooltip: l10n.librarySort,
        icon: const Icon(Icons.sort),
        initialValue: _query.sort,
        onSelected: (sort) =>
            setState(() => _query = _query.copyWith(sort: sort)),
        itemBuilder: (context) => [
          for (final (sort, label) in [
            (LibrarySort.latest, l10n.sortRecentlyAdded),
            (LibrarySort.oldest, l10n.sortOldest),
            (LibrarySort.title, l10n.sortTitle),
            (LibrarySort.artist, l10n.sortArtist),
            (LibrarySort.album, l10n.sortAlbum),
            (LibrarySort.year, l10n.sortYear),
            (LibrarySort.genre, l10n.sortGenre),
            (LibrarySort.size, l10n.sortSize),
          ])
            PopupMenuItem(value: sort, child: Text(label)),
        ],
      ),
      IconButton(
        tooltip: _grid ? l10n.libraryShowList : l10n.libraryShowGrid,
        icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
        onPressed: () => setState(() => _grid = !_grid),
      ),
    ];
  }

  Widget _songs(AppLocalizations l10n) {
    final count = ref.watch(songCountProvider(_query)).asData?.value;
    if (count == 0) {
      if (_query.activeFilters > 0) {
        return EmptyState(
          icon: _query.favoritesOnly
              ? Icons.favorite_border
              : Icons.filter_list_off,
          title: _query.favoritesOnly
              ? l10n.favoritesEmptyTitle
              : l10n.libraryViewEmpty,
          body: _query.favoritesOnly ? l10n.favoritesEmptyBody : '',
        );
      }
      return EmptyState(
        icon: Icons.library_music_outlined,
        title: l10n.libraryEmptyTitle,
        body: l10n.libraryEmptyBody,
      );
    }
    return PagedSongList(
      query: _query,
      grid: _grid,
      selected: _selected,
      onTap: _open,
      onLongPress: _toggle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tab = _tab;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
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
                    onPressed: _selectAll,
                  ),
                  IconButton(
                    tooltip: l10n.queueAdd,
                    icon: const Icon(Icons.queue_music),
                    onPressed: _queueSelected,
                  ),
                  IconButton(
                    tooltip: l10n.playlistAddTo,
                    icon: const Icon(Icons.playlist_add),
                    onPressed: _playlistSelected,
                  ),
                  IconButton(
                    tooltip: l10n.favoriteAdd,
                    icon: const Icon(Icons.favorite_border),
                    onPressed: _favoriteSelected,
                  ),
                  IconButton(
                    tooltip: l10n.actionDelete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _deleteSelected,
                  ),
                ],
              )
            : AppBar(
                title: Text(l10n.navLibrary),
                actions: [
                  if (tab == LibraryTab.songs) ..._songActions(l10n),
                  IconButton(
                    tooltip: l10n.foldersTitle,
                    icon: const Icon(Icons.folder_outlined),
                    onPressed: () => context.push('/settings/folders'),
                  ),
                ],
                bottom: _tabs(l10n),
              ),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                heroTag: 'import-library',
                onPressed: () => pickAndImport(context, ref),
                icon: const Icon(Icons.add),
                label: Text(l10n.importAction),
              ),
        body: switch (tab) {
          LibraryTab.songs => _songs(l10n),
          LibraryTab.albums => const AlbumsView(),
          LibraryTab.artists => const ArtistsView(),
          LibraryTab.genres => const GenresView(),
          LibraryTab.folders => const FoldersView(),
          LibraryTab.playlists => const PlaylistsView(),
        },
      ),
    );
  }
}
