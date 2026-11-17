import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/queue_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Learn | Karaoke, for a queue entry or the player.
class PlayModeButton extends StatelessWidget {
  const PlayModeButton({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final PlayMode mode;
  final ValueChanged<PlayMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<PlayMode>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: PlayMode.learn,
          icon: const Icon(Icons.school_outlined),
          label: Text(l10n.modeLearn),
        ),
        ButtonSegment(
          value: PlayMode.karaoke,
          icon: const Icon(Icons.mic_external_on_outlined),
          label: Text(l10n.modeKaraoke),
        ),
      ],
      // History rows from before modes existed say `listen`.
      selected: {mode == PlayMode.karaoke ? PlayMode.karaoke : PlayMode.learn},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// Asks who sings [song] and in which mode, then adds it to the queue.
Future<void> showAddToQueueSheet(
  BuildContext context,
  WidgetRef ref,
  Song song,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _QueueEntrySheet(song: song),
);

/// The singer and mode of a new ([entry] null) or existing queue entry.
class _QueueEntrySheet extends ConsumerStatefulWidget {
  const _QueueEntrySheet({required this.song, this.entry});

  final Song song;
  final QueueEntry? entry;

  @override
  ConsumerState<_QueueEntrySheet> createState() => _QueueEntrySheetState();
}

class _QueueEntrySheetState extends ConsumerState<_QueueEntrySheet> {
  late final _singer = TextEditingController(text: widget.entry?.item.singer);
  late PlayMode _mode = widget.entry?.item.mode ?? PlayMode.karaoke;

  @override
  void dispose() {
    _singer.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(queueActionsProvider);
    final entry = widget.entry;
    Navigator.pop(context);
    if (entry == null) {
      await actions.add(widget.song, singer: _singer.text, mode: _mode);
      messenger.showSnackBar(SnackBar(content: Text(l10n.queueAdded)));
    } else {
      await actions.update(entry.item, singer: _singer.text, mode: _mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: AppTokens.space16,
        right: AppTokens.space16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppTokens.space16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.song.title,
            style: Theme.of(context).textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppTokens.space12),
          TextField(
            controller: _singer,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: l10n.queueSinger,
              hintText: l10n.queueSingerHint,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppTokens.space12),
          PlayModeButton(
            mode: _mode,
            onChanged: (mode) => setState(() => _mode = mode),
          ),
          const SizedBox(height: AppTokens.space16),
          FilledButton(
            onPressed: _submit,
            child: Text(widget.entry == null ? l10n.queueAdd : l10n.actionSave),
          ),
        ],
      ),
    );
  }
}

/// The singing queue (M3.4): reorder by dragging, tap to sing now, edit the
/// singer and mode, remove. The first entry starts when the current song
/// ends.
class QueueTab extends ConsumerWidget {
  const QueueTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entries = ref.watch(queueProvider).asData?.value ?? const [];
    final actions = ref.read(queueActionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navQueue),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: l10n.queueClear,
              icon: const Icon(Icons.clear_all),
              onPressed: actions.clear,
            ),
        ],
      ),
      body: entries.isEmpty
          ? EmptyState(
              icon: Icons.queue_music,
              title: l10n.queueEmptyTitle,
              body: l10n.queueEmptyBody,
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: entries.length,
              onReorderItem: actions.move,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final singer = entry.item.singer;
                final mode = entry.item.mode == PlayMode.karaoke
                    ? l10n.modeKaraoke
                    : l10n.modeLearn;
                return ListTile(
                  key: ValueKey(entry.item.id),
                  leading: SongCover(song: entry.song),
                  title: Text(
                    entry.song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [if (singer.isNotEmpty) singer, mode].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.queueEdit,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          showDragHandle: true,
                          builder: (_) =>
                              _QueueEntrySheet(song: entry.song, entry: entry),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.queueRemove,
                        icon: const Icon(Icons.close),
                        onPressed: () => actions.remove(entry.item),
                      ),
                      // Room for the drag handle the list adds on desktop.
                      const SizedBox(width: AppTokens.space24),
                    ],
                  ),
                  onTap: () async {
                    await actions.play(entry);
                    if (context.mounted) await context.push('/player');
                  },
                );
              },
            ),
    );
  }
}
