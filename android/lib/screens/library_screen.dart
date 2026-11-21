import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/screens/home_tab.dart';
import 'package:kalao/screens/import_sheet.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Library: grid or list, sort, and a selection mode (long press) for
/// deleting songs.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  SongSort _sort = SongSort.recentlyAdded;
  bool _grid = false;
  bool _favoritesOnly = false;
  final _selected = <int>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(Song song) => setState(() {
    if (!_selected.remove(song.id)) _selected.add(song.id);
  });

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final songs = ref.watch(
      librarySongsProvider((sort: _sort, favoritesOnly: _favoritesOnly)),
    );
    final list = songs.asData?.value ?? const <Song>[];
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
                    onPressed: () =>
                        setState(() => _selected.addAll(list.map((s) => s.id))),
                  ),
                  IconButton(
                    tooltip: l10n.queueAdd,
                    icon: const Icon(Icons.playlist_add),
                    onPressed: () => _queueSelected(list),
                  ),
                  IconButton(
                    tooltip: l10n.favoriteAdd,
                    icon: const Icon(Icons.favorite_border),
                    onPressed: () => _favoriteSelected(),
                  ),
                  IconButton(
                    tooltip: l10n.actionDelete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteSelected(list),
                  ),
                ],
              )
            : AppBar(
                title: Text(l10n.navLibrary),
                actions: [
                  IconButton(
                    tooltip: l10n.libraryFavoritesOnly,
                    isSelected: _favoritesOnly,
                    icon: const Icon(Icons.favorite_border),
                    selectedIcon: const Icon(Icons.favorite),
                    onPressed: () =>
                        setState(() => _favoritesOnly = !_favoritesOnly),
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
                      PopupMenuItem(
                        value: SongSort.title,
                        child: Text(l10n.sortTitle),
                      ),
                      PopupMenuItem(
                        value: SongSort.artist,
                        child: Text(l10n.sortArtist),
                      ),
                    ],
                  ),
                  IconButton(
                    tooltip: l10n.foldersTitle,
                    icon: const Icon(Icons.folder_outlined),
                    onPressed: () => context.push('/settings/folders'),
                  ),
                  IconButton(
                    tooltip: _grid
                        ? l10n.libraryShowList
                        : l10n.libraryShowGrid,
                    icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
                    onPressed: () => setState(() => _grid = !_grid),
                  ),
                ],
              ),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                heroTag: 'import-library',
                onPressed: () => pickAndImport(context, ref),
                icon: const Icon(Icons.add),
                label: Text(l10n.importAction),
              ),
        body: switch (songs) {
          AsyncData(:final value) when value.isEmpty && _favoritesOnly =>
            EmptyState(
              icon: Icons.favorite_border,
              title: l10n.favoritesEmptyTitle,
              body: l10n.favoritesEmptyBody,
            ),
          AsyncData(:final value) when value.isEmpty => EmptyState(
            icon: Icons.library_music_outlined,
            title: l10n.libraryEmptyTitle,
            body: l10n.libraryEmptyBody,
          ),
          AsyncError(:final error) => Center(child: Text('$error')),
          AsyncData(:final value) =>
            _grid ? _buildGrid(value) : _buildList(value),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
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

  void _open(Song song) {
    if (_selecting) {
      _toggle(song);
    } else {
      openSong(context, ref, song);
    }
  }

  Widget _buildList(List<Song> songs) => ListView.builder(
    padding: const EdgeInsets.only(bottom: 96),
    itemCount: songs.length,
    itemBuilder: (context, index) {
      final song = songs[index];
      return SongListTile(
        song: song,
        selectionMode: _selecting,
        selected: _selected.contains(song.id),
        onTap: () => _open(song),
        onLongPress: () => _toggle(song),
      );
    },
  );

  Widget _buildGrid(List<Song> songs) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space12,
      AppTokens.space8,
      AppTokens.space12,
      96,
    ),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 180,
      childAspectRatio: 0.72,
    ),
    itemCount: songs.length,
    itemBuilder: (context, index) {
      final song = songs[index];
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
  );
}
