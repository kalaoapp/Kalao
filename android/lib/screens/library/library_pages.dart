// The Library's pages, after Mornye's local_album_screen.dart,
// library_artist_screen.dart and library_directory_view.dart: an album in
// disc and track order, an artist's albums or songs, a genre, and a music
// folder's tree, each with Sing all and Shuffle (FEATURES 6.11).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/screens/home_tab.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/providers/album_artwork_provider.dart';
import 'package:kalao/providers/library_folder_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/library/library_actions.dart';
import 'package:kalao/widgets/library/paged_song_list.dart';
import 'package:kalao/widgets/song_widgets.dart';

Future<void> _push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

void openAlbum(BuildContext context, AlbumRef album) =>
    _push(context, AlbumScreen(album: album));

void openArtist(BuildContext context, String artist) =>
    _push(context, ArtistScreen(artist: artist));

void openGenre(BuildContext context, GenreSummary genre) => _push(
  context,
  SongsScreen(
    title: genre.name,
    query: SongQuery(genre: genre.key),
  ),
);

void openFolder(BuildContext context, FolderRef folder, String title) =>
    _push(context, FolderScreen(folder: folder, title: title));

/// Sing all, Shuffle and Queue all over [query].
class SingAllBar extends ConsumerWidget {
  const SingAllBar({super.key, required this.query});

  final SongQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    Future<void> withIds(
      Future<void> Function(BuildContext context, List<int> ids) action,
    ) async {
      final ids = await ref.read(libraryServicesProvider).browse.ids(query);
      if (context.mounted) await action(context, ids);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space8,
        AppTokens.space16,
        AppTokens.space8,
      ),
      child: Wrap(
        spacing: AppTokens.space8,
        runSpacing: AppTokens.space8,
        children: [
          FilledButton.icon(
            onPressed: () => withIds((c, ids) => singAll(c, ref, ids)),
            icon: const Icon(Icons.mic),
            label: Text(l10n.librarySingAll),
          ),
          FilledButton.tonalIcon(
            onPressed: () =>
                withIds((c, ids) => singAll(c, ref, ids, shuffle: true)),
            icon: const Icon(Icons.shuffle),
            label: Text(l10n.libraryShuffle),
          ),
          OutlinedButton.icon(
            onPressed: () => withIds((c, ids) => queueAll(c, ref, ids)),
            icon: const Icon(Icons.queue_music),
            label: Text(l10n.libraryQueueAll),
          ),
        ],
      ),
    );
  }
}

/// A titled list of [query]'s songs.
class SongsScreen extends ConsumerWidget {
  const SongsScreen({
    super.key,
    required this.title,
    required this.query,
    this.actions = const [],
    this.header,
  });

  final String title;
  final SongQuery query;
  final List<Widget> actions;
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final count = ref.watch(songCountProvider(query)).asData?.value;
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: count == 0
          ? EmptyState(
              icon: Icons.library_music_outlined,
              title: l10n.libraryViewEmpty,
              body: '',
            )
          : PagedSongList(
              query: query,
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ?header,
                  SingAllBar(query: query),
                ],
              ),
              onTap: (song) => openSong(context, ref, song),
            ),
    );
  }
}

enum _AlbumAction { removeArtwork }

class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({super.key, required this.album});

  final AlbumRef album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final query = SongQuery(album: album);
    final first = ref
        .watch(songPageProvider((query: query, page: 0)))
        .asData
        ?.value
        .firstOrNull;
    final count = ref.watch(songCountProvider(query)).asData?.value ?? 0;
    return SongsScreen(
      title: album.name,
      query: query,
      actions: [
        PopupMenuButton<_AlbumAction>(
          onSelected: (_) async {
            await ref
                .read(libraryServicesProvider)
                .maintenance
                .removeCover(album);
            ref.read(libraryRevisionProvider.notifier).bump();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _AlbumAction.removeArtwork,
              enabled: first?.coverPath != null,
              child: Text(l10n.artworkRemove),
            ),
          ],
        ),
      ],
      header: Padding(
        padding: const EdgeInsets.all(AppTokens.space16),
        child: Row(
          children: [
            if (first != null)
              SongCover(song: first, size: 112, radius: AppTokens.radiusMedium),
            const SizedBox(width: AppTokens.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (album.artist.isNotEmpty)
                    InkWell(
                      onTap: () => openArtist(context, album.artist),
                      child: Text(album.artist),
                    ),
                  Text(
                    [
                      l10n.librarySongCount(count),
                      if (first?.year case final year?) '$year',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
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

/// An artist's albums or songs, whichever was chosen last.
class ArtistScreen extends ConsumerStatefulWidget {
  const ArtistScreen({super.key, required this.artist});

  final String artist;

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  static bool _showSongs = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final query = SongQuery(artist: widget.artist, sort: LibrarySort.album);
    final albums = ref.watch(albumsProvider(widget.artist)).asData?.value;
    final toggle = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space8,
        AppTokens.space16,
        0,
      ),
      child: SegmentedButton<bool>(
        segments: [
          ButtonSegment(value: false, label: Text(l10n.libraryViewAlbums)),
          ButtonSegment(value: true, label: Text(l10n.libraryViewSongs)),
        ],
        selected: {_showSongs},
        onSelectionChanged: (value) => setState(() => _showSongs = value.first),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(widget.artist)),
      body: _showSongs || (albums != null && albums.isEmpty)
          ? PagedSongList(
              query: query,
              header: Column(
                children: [
                  toggle,
                  SingAllBar(query: query),
                ],
              ),
              onTap: (song) => openSong(context, ref, song),
            )
          : ListView(
              children: [
                toggle,
                SingAllBar(query: query),
                for (final album in albums ?? const <AlbumSummary>[])
                  AlbumTile(album: album),
              ],
            ),
    );
  }
}

class AlbumTile extends StatelessWidget {
  const AlbumTile({super.key, required this.album});

  final AlbumSummary album;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: _Cover(path: album.coverPath),
      title: Text(album.ref.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (album.ref.artist.isNotEmpty) album.ref.artist,
          l10n.librarySongCount(album.songs),
          if (album.year case final year?) '$year',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => openAlbum(context, album.ref),
    );
  }
}

/// A cover file, or the placeholder.
class _Cover extends StatelessWidget {
  const _Cover({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) => SongCover(
    song: Song(
      id: 0,
      title: '',
      coverPath: path,
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
}

class AlbumsView extends ConsumerWidget {
  const AlbumsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final albums = ref.watch(albumsProvider(null));
    return switch (albums) {
      AsyncData(:final value) when value.isEmpty => EmptyState(
        icon: Icons.album_outlined,
        title: l10n.libraryViewEmpty,
        body: l10n.libraryAlbumsEmpty,
      ),
      AsyncData(:final value) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: value.length,
        itemBuilder: (context, index) => AlbumTile(album: value[index]),
      ),
      AsyncError(:final error) => Center(child: Text('$error')),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class ArtistsView extends ConsumerWidget {
  const ArtistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return switch (ref.watch(artistsProvider)) {
      AsyncData(:final value) when value.isEmpty => EmptyState(
        icon: Icons.person_outline,
        title: l10n.libraryViewEmpty,
        body: '',
      ),
      AsyncData(:final value) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: value.length,
        itemBuilder: (context, index) {
          final artist = value[index];
          return ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
            title: Text(artist.name),
            subtitle: Text(l10n.librarySongCount(artist.songs)),
            onTap: () => openArtist(context, artist.name),
          );
        },
      ),
      AsyncError(:final error) => Center(child: Text('$error')),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class GenresView extends ConsumerWidget {
  const GenresView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return switch (ref.watch(genresProvider)) {
      AsyncData(:final value) when value.isEmpty => EmptyState(
        icon: Icons.category_outlined,
        title: l10n.libraryViewEmpty,
        body: l10n.libraryGenresEmpty,
      ),
      AsyncData(:final value) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: value.length,
        itemBuilder: (context, index) {
          final genre = value[index];
          return ListTile(
            leading: const Icon(Icons.category_outlined),
            title: Text(genre.name),
            subtitle: Text(l10n.librarySongCount(genre.songs)),
            onTap: () => openGenre(context, genre),
          );
        },
      ),
      AsyncError(:final error) => Center(child: Text('$error')),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// The music folders, each opening its tree.
class FoldersView extends ConsumerWidget {
  const FoldersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(libraryFoldersProvider);
    if (!state.loaded) return const Center(child: CircularProgressIndicator());
    final folders = state.folders;
    if (folders.isEmpty) {
      return EmptyState(
        icon: Icons.folder_outlined,
        title: l10n.libraryViewEmpty,
        body: l10n.libraryFoldersEmpty,
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final folder in folders)
          ListTile(
            leading: Icon(
              folder.isOffline || folder.accessLost
                  ? Icons.folder_off_outlined
                  : Icons.folder_outlined,
            ),
            title: Text(folder.name),
            subtitle: Text(l10n.librarySongCount(folder.songs)),
            onTap: () =>
                openFolder(context, FolderRef(folder.id, ''), folder.name),
          ),
      ],
    );
  }
}

/// One level of a music folder: Sing all for everything under it, its
/// subfolders, then its own songs.
class FolderScreen extends ConsumerWidget {
  const FolderScreen({super.key, required this.folder, required this.title});

  final FolderRef folder;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final level = ref.watch(folderLevelProvider(folder)).asData?.value;
    final songs = ref.watch(folderSongsProvider(folder)).asData?.value;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: level == null || songs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                SingAllBar(query: SongQuery(folder: folder)),
                for (final dir in level.dirs)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(dir.name),
                    subtitle: Text(l10n.librarySongCount(dir.songs)),
                    onTap: () => openFolder(
                      context,
                      FolderRef(folder.folderId, dir.dir),
                      dir.name,
                    ),
                  ),
                for (final song in songs)
                  SongListTile(
                    song: song,
                    onTap: () => openSong(context, ref, song),
                  ),
              ],
            ),
    );
  }
}

/// Local playlists (FEATURES 6.14).
class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final playlists = ref.watch(playlistsProvider).asData?.value;
    if (playlists == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(l10n.playlistNew),
          onTap: () async {
            final name = await askPlaylistName(
              context,
              title: l10n.playlistNew,
            );
            if (name == null) return;
            await ref.read(libraryServicesProvider).playlists.create(name);
            ref.read(libraryRevisionProvider.notifier).bump();
          },
        ),
        for (final playlist in playlists)
          ListTile(
            leading: _Cover(path: playlist.coverPath),
            title: Text(playlist.name),
            subtitle: Text(l10n.librarySongCount(playlist.songs)),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PlaylistScreen(id: playlist.id, name: playlist.name),
              ),
            ),
          ),
        if (playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Text(l10n.playlistEmpty),
          ),
      ],
    );
  }
}

enum _PlaylistAction { rename, delete }

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  late String _name = widget.name;

  Future<void> _menu(_PlaylistAction action) async {
    final l10n = AppLocalizations.of(context);
    final store = ref.read(libraryServicesProvider).playlists;
    switch (action) {
      case _PlaylistAction.rename:
        final name = await askPlaylistName(
          context,
          initial: _name,
          title: l10n.playlistRename,
        );
        if (name == null) return;
        await store.rename(widget.id, name);
        setState(() => _name = name);
      case _PlaylistAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.playlistDelete),
            content: Text(l10n.playlistDeleteConfirm(_name)),
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
        await store.delete(widget.id);
        if (mounted) Navigator.of(context).pop();
    }
    ref.read(libraryRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries =
        ref.watch(playlistSongsProvider(widget.id)).asData?.value ?? const [];
    final ids = [for (final entry in entries) entry.song.id];
    final store = ref.read(libraryServicesProvider).playlists;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          PopupMenuButton<_PlaylistAction>(
            onSelected: _menu,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _PlaylistAction.rename,
                child: Text(l10n.playlistRename),
              ),
              PopupMenuItem(
                value: _PlaylistAction.delete,
                child: Text(l10n.playlistDelete),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
            child: Wrap(
              spacing: AppTokens.space8,
              children: [
                FilledButton.icon(
                  onPressed: ids.isEmpty
                      ? null
                      : () => singAll(context, ref, ids),
                  icon: const Icon(Icons.mic),
                  label: Text(l10n.librarySingAll),
                ),
                FilledButton.tonalIcon(
                  onPressed: ids.isEmpty
                      ? null
                      : () => singAll(context, ref, ids, shuffle: true),
                  icon: const Icon(Icons.shuffle),
                  label: Text(l10n.libraryShuffle),
                ),
                OutlinedButton.icon(
                  onPressed: ids.isEmpty
                      ? null
                      : () => queueAll(context, ref, ids),
                  icon: const Icon(Icons.queue_music),
                  label: Text(l10n.libraryQueueAll),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(child: Text(l10n.playlistEmpty))
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: entries.length,
                    onReorderItem: (from, to) async {
                      final order = [for (final e in entries) e.itemId];
                      final moved = order.removeAt(from);
                      order.insert(to, moved);
                      await store.reorder(widget.id, order);
                      ref.read(libraryRevisionProvider.notifier).bump();
                    },
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return Dismissible(
                        key: ValueKey(entry.itemId),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) async {
                          await store.removeItem(widget.id, entry.itemId);
                          ref.read(libraryRevisionProvider.notifier).bump();
                        },
                        background: ColoredBox(
                          color: Theme.of(context).colorScheme.errorContainer,
                        ),
                        child: SongListTile(
                          song: entry.song,
                          onTap: () => openSong(context, ref, entry.song),
                          trailing: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Review duplicates (FEATURES 6.13): copies of a song across music
/// folders, imports and downloads; keeping one moves the others' lyrics,
/// favorites and plays to it.
class DuplicatesScreen extends ConsumerStatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  ConsumerState<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends ConsumerState<DuplicatesScreen> {
  late Future<List<List<Song>>> _groups = _load();

  Future<List<List<Song>>> _load() =>
      ref.read(libraryServicesProvider).maintenance.duplicateGroups();

  String _where(AppLocalizations l10n, Song song) {
    final original = song.file(MediaKind.original);
    if (song.fromExtension) return l10n.originExtension;
    if (original?.inFolder ?? false) return l10n.originFolder;
    return l10n.originImported;
  }

  Future<void> _keep(Song kept, List<Song> group) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final maintenance = ref.read(libraryServicesProvider).maintenance;
    await maintenance.keep(kept, group);
    ref.read(libraryRevisionProvider.notifier).bump();
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.duplicatesMerged(group.length - 1))),
    );
    setState(() => _groups = _load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.duplicatesTitle)),
      body: FutureBuilder(
        future: _groups,
        builder: (context, snapshot) {
          final groups = snapshot.data;
          if (groups == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (groups.isEmpty) {
            return EmptyState(
              icon: Icons.done_all,
              title: l10n.duplicatesNone,
              body: '',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.all(AppTokens.space16),
                child: Text(l10n.duplicatesHint),
              ),
              for (final group in groups)
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: AppTokens.space16,
                    vertical: AppTokens.space8,
                  ),
                  child: Column(
                    children: [
                      for (final song in group)
                        ListTile(
                          leading: SongCover(song: song),
                          title: Text(song.title),
                          subtitle: Text(
                            [
                              if (song.artist.isNotEmpty) song.artist,
                              _where(l10n, song),
                              if (song.hasLyrics) l10n.songHasLyrics,
                            ].join(' · '),
                          ),
                          trailing: TextButton(
                            onPressed: () => _keep(song, group),
                            child: Text(l10n.duplicatesKeep),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Find Missing Artwork (FEATURES 6.13), with its progress.
Future<void> findMissingArtwork(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final controller = ref.read(albumArtworkProvider.notifier);
  if (!await controller.hasArtworkExtension()) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.artworkNoExtension)));
    return;
  }
  if (!context.mounted) return;
  final run = controller.run();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(albumArtworkProvider);
        return AlertDialog(
          title: Text(l10n.artworkTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: state.total == 0 ? null : state.done / state.total,
              ),
              const SizedBox(height: AppTokens.space12),
              Text(l10n.artworkProgress(state.done, state.total)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: state.running
                  ? controller.cancel
                  : () => Navigator.pop(context),
              child: Text(state.running ? l10n.actionCancel : l10n.actionOk),
            ),
          ],
        );
      },
    ),
  );
  final found = await run;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        found == null ? l10n.artworkNothing : l10n.artworkResult(found),
      ),
    ),
  );
}
