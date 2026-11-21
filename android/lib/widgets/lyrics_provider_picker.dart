import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/services/extension_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// Searches every lyrics extension for [song] and lets the user pick a
/// candidate (FEATURES 2.11; the role of Mornye's lyrics provider picker).
/// Synced lyrics and close matches come first.
Future<void> showLyricsProviderPicker(
  BuildContext context,
  WidgetRef ref,
  Song song,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => LyricsProviderPicker(song: song),
);

class LyricsProviderPicker extends ConsumerStatefulWidget {
  const LyricsProviderPicker({super.key, required this.song});

  final Song song;

  @override
  ConsumerState<LyricsProviderPicker> createState() =>
      _LyricsProviderPickerState();
}

class _LyricsProviderPickerState extends ConsumerState<LyricsProviderPicker> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(text: widget.song.artist);
  Future<({List<LyricsCandidate> candidates, List<ExtensionFailure> errors})>?
  _search;
  String? _importing;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  void _run() {
    final base = ExtensionService.queryFor(widget.song);
    setState(() {
      _search = ref
          .read(extensionServiceProvider)
          .searchLyrics(
            TrackQuery(
              title: _title.text.trim(),
              artist: _artist.text.trim(),
              album: base.album,
              durationMs: base.durationMs,
              isrc: base.isrc,
              language: base.language,
            ),
          );
    });
  }

  Future<void> _pick(LyricsCandidate candidate) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _importing = '${candidate.extensionId}/${candidate.id}');
    try {
      await ref
          .read(extensionServiceProvider)
          .importLyrics(widget.song.id, candidate);
      ref.read(libraryRevisionProvider.notifier).bump();
      if (ref.read(playerProvider).song?.id == widget.song.id) {
        await ref.read(playerProvider.notifier).reloadLyrics();
      }
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.lyricsFetched(candidate.extensionName))),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      if (mounted) setState(() => _importing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space16,
              ),
              child: Text(
                l10n.lyricsSearchOnline,
                style: theme.textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppTokens.space16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _title,
                      decoration: InputDecoration(labelText: l10n.songTitle),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  const SizedBox(width: AppTokens.space8),
                  Expanded(
                    child: TextField(
                      controller: _artist,
                      decoration: InputDecoration(labelText: l10n.songArtist),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.searchAction,
                    icon: const Icon(Icons.search),
                    onPressed: _run,
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder(
                future: _search,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('${snapshot.error}'));
                  }
                  final result = snapshot.data!;
                  return ListView(
                    children: [
                      if (result.candidates.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppTokens.space24),
                          child: Text(
                            l10n.lyricsSearchNone,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      for (final candidate in result.candidates)
                        ListTile(
                          leading: Icon(
                            candidate.synced
                                ? Icons.av_timer
                                : Icons.notes_outlined,
                          ),
                          title: Text(
                            candidate.artist.isEmpty
                                ? candidate.title
                                : '${candidate.title} · ${candidate.artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              candidate.extensionName,
                              candidate.synced
                                  ? l10n.lyricsSynced
                                  : l10n.lyricsPlain,
                              if (candidate.durationMs case final ms?)
                                formatDuration(Duration(milliseconds: ms)),
                            ].join(' · '),
                          ),
                          trailing:
                              _importing ==
                                  '${candidate.extensionId}/${candidate.id}'
                              ? const SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          onTap: _importing == null
                              ? () => _pick(candidate)
                              : null,
                        ),
                      for (final failure in result.errors)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.error,
                          ),
                          title: Text(l10n.extensionFailed(failure.name)),
                          subtitle: Text(
                            failure.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
