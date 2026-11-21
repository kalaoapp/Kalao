import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/screens/home_tab.dart';

/// Sing all (or Shuffle): plays the first playable song of [ids] and
/// queues the rest after it, without touching what was queued already.
Future<void> singAll(
  BuildContext context,
  WidgetRef ref,
  List<int> ids, {
  bool shuffle = false,
}) async {
  final order = shuffle ? shuffled(ids) : ids;
  final songs = [
    for (final song
        in await ref.read(libraryServicesProvider).library.songsByIds(order))
      if (song.playable) song,
  ];
  if (songs.isEmpty || !context.mounted) return;
  final queue = ref.read(queueActionsProvider);
  for (final song in songs.skip(1)) {
    await queue.add(song);
  }
  if (context.mounted) await openSong(context, ref, songs.first);
}

/// Adds [ids] to the queue in order.
Future<void> queueAll(
  BuildContext context,
  WidgetRef ref,
  List<int> ids,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final queue = ref.read(queueActionsProvider);
  for (final song
      in await ref.read(libraryServicesProvider).library.songsByIds(ids)) {
    if (song.playable) await queue.add(song);
  }
  messenger.showSnackBar(SnackBar(content: Text(l10n.queueAdded)));
}

/// Asks for a name; null when cancelled or empty.
Future<String?> askPlaylistName(
  BuildContext context, {
  String initial = '',
  required String title,
}) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.playlistName),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(l10n.actionSave),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Picks a playlist (or makes a new one) and adds [ids] to it.
Future<void> addToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<int> ids,
) async {
  if (ids.isEmpty) return;
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final store = ref.read(libraryServicesProvider).playlists;
  final playlists = await store.playlists();
  if (!context.mounted) return;
  final chosen = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l10n.playlistNew),
            onTap: () => Navigator.pop(context, -1),
          ),
          for (final playlist in playlists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              subtitle: Text(l10n.librarySongCount(playlist.songs)),
              onTap: () => Navigator.pop(context, playlist.id),
            ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  var id = chosen;
  var name = '';
  if (chosen == -1) {
    final named = await askPlaylistName(context, title: l10n.playlistNew);
    if (named == null) return;
    id = await store.create(named);
    name = named;
  } else {
    name = playlists.firstWhere((playlist) => playlist.id == chosen).name;
  }
  await store.add(id, ids);
  ref.read(libraryRevisionProvider.notifier).bump();
  messenger.showSnackBar(
    SnackBar(content: Text(l10n.playlistAdded(ids.length, name))),
  );
}
