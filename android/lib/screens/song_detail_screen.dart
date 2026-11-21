import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/screens/home_tab.dart';
import 'package:kalao/screens/queue_tab.dart';
import 'package:kalao/services/extension_service.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/lyrics_provider_picker.dart';
import 'package:kalao/widgets/song_widgets.dart';

final _songProvider = FutureProvider.autoDispose.family<Song?, int>((ref, id) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryServicesProvider).library.song(id);
});

/// A library song's details (FEATURES 6.4): its tags, where it came from,
/// details and artwork from metadata extensions, lyrics from lyrics
/// extensions, and the offline download of an extension song (6.6).
class SongDetailScreen extends ConsumerStatefulWidget {
  const SongDetailScreen({super.key, required this.songId});

  final int songId;

  @override
  ConsumerState<SongDetailScreen> createState() => _SongDetailScreenState();
}

class _SongDetailScreenState extends ConsumerState<SongDetailScreen> {
  bool _downloading = false;

  Future<void> _download(Song song) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _downloading = true);
    try {
      await ref.read(extensionServiceProvider).download(song);
      ref.read(libraryRevisionProvider.notifier).bump();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.downloadDone(song.title))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.downloadFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _findDetails(Song song) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final track = await showModalBottomSheet<TrackResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MetadataPicker(query: ExtensionService.queryFor(song)),
    );
    if (track == null) return;
    try {
      await ref.read(extensionServiceProvider).applyDetails(song, track);
      ref.read(libraryRevisionProvider.notifier).bump();
      messenger.showSnackBar(SnackBar(content: Text(l10n.detailsApplied)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final song = ref.watch(_songProvider(widget.songId)).asData?.value;
    final extensions = ref.watch(extensionsProvider);
    if (song == null) return Scaffold(appBar: AppBar());
    final source = song.extRef == null
        ? null
        : extensions.byId(song.extRef!.extensionId)?.manifest.name ??
              song.extRef!.extensionId;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.songDetails)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.space16),
        children: [
          Center(
            child: SongCover(
              song: song,
              size: 180,
              radius: AppTokens.radiusLarge,
            ),
          ),
          const SizedBox(height: AppTokens.space16),
          Text(
            song.title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          if (song.artist.isNotEmpty)
            Text(
              song.artist,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: AppTokens.space16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppTokens.space8,
            children: [
              FilledButton.icon(
                onPressed: song.playable
                    ? () => openSong(context, ref, song)
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.songPlay),
              ),
              OutlinedButton.icon(
                onPressed: () => showAddToQueueSheet(context, ref, song),
                icon: const Icon(Icons.playlist_add),
                label: Text(l10n.queueAdd),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space16),
          _Fact(l10n.songAlbum, song.album),
          _Fact(l10n.songDuration, formatDuration(song.duration)),
          _Fact('ISRC', song.isrc ?? ''),
          _Fact(l10n.songLanguage, song.language ?? ''),
          _Fact(
            l10n.songSource,
            source == null
                ? l10n.songSourceLocal
                : song.streams
                ? l10n.songSourceStream(source)
                : l10n.songSourceDownloaded(source),
          ),
          const Divider(),
          if (extensions.has(ExtensionCapability.metadata))
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: Text(l10n.detailsFind),
              subtitle: Text(l10n.detailsFindBody),
              onTap: () => _findDetails(song),
            ),
          if (extensions.has(ExtensionCapability.lyrics))
            ListTile(
              leading: const Icon(Icons.lyrics_outlined),
              title: Text(l10n.lyricsSearchOnline),
              subtitle: Text(
                song.hasLyrics ? l10n.lyricsSearchReplace : l10n.lyricsNone,
              ),
              onTap: () => showLyricsProviderPicker(context, ref, song),
            ),
          if (song.streams)
            ListTile(
              leading: _downloading
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              title: Text(l10n.downloadOffline),
              subtitle: Text(l10n.downloadOfflineBody),
              onTap: _downloading ? null : () => _download(song),
            ),
          if (!extensions.has(ExtensionCapability.metadata) &&
              !extensions.has(ExtensionCapability.lyrics))
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(l10n.detailsNoExtensions),
              onTap: () => context.go('/'),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ListTile(dense: true, title: Text(label), subtitle: Text(value));
  }
}

/// Metadata search results to choose details from.
class MetadataPicker extends ConsumerStatefulWidget {
  const MetadataPicker({super.key, required this.query});

  final TrackQuery query;

  @override
  ConsumerState<MetadataPicker> createState() => _MetadataPickerState();
}

class _MetadataPickerState extends ConsumerState<MetadataPicker> {
  late final _search = ref
      .read(extensionServiceProvider)
      .searchTracks(widget.query);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: FutureBuilder(
          future: _search,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('${snapshot.error}'));
            }
            final tracks = snapshot.data!.tracks;
            if (tracks.isEmpty) {
              return Center(child: Text(l10n.searchNoResults));
            }
            return ListView(
              children: [
                for (final track in tracks)
                  TrackTile(
                    track: track,
                    onTap: () => Navigator.pop(context, track),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A metadata result: title, artists, album, source extension.
class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.track, this.onTap, this.trailing});

  final TrackResult track;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const CircleAvatar(child: Icon(Icons.cloud_outlined)),
    title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        if (track.artist.isNotEmpty) track.artist,
        ?track.album,
        if (track.durationMs case final ms?)
          formatDuration(Duration(milliseconds: ms)),
        track.extensionName,
      ].join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: trailing,
    onTap: onTap,
  );
}

/// A metadata result not in the library yet: play it (streams), add it,
/// or download it (FEATURES 1.8, 6.2, 6.6).
class TrackDetailScreen extends ConsumerStatefulWidget {
  const TrackDetailScreen({super.key, required this.track});

  final TrackResult track;

  @override
  ConsumerState<TrackDetailScreen> createState() => _TrackDetailScreenState();
}

class _TrackDetailScreenState extends ConsumerState<TrackDetailScreen> {
  bool _busy = false;

  Future<Song?> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final song = await ref
          .read(extensionServiceProvider)
          .addTrack(widget.track);
      ref.read(libraryRevisionProvider.notifier).bump();
      return song;
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      return null;
    }
  }

  Future<void> _run(Future<void> Function(Song song) then) async {
    setState(() => _busy = true);
    try {
      final song = await _add();
      if (song != null && mounted) await then(song);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final track = widget.track;
    final canPlay = ref
        .watch(extensionsProvider)
        .has(ExtensionCapability.audio);
    final router = GoRouter.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.songDetails)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.space16),
        children: [
          Text(track.title, style: theme.textTheme.headlineSmall),
          if (track.artist.isNotEmpty)
            Text(track.artist, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTokens.space8),
          _Fact(l10n.songAlbum, track.album ?? ''),
          _Fact(
            l10n.songDuration,
            track.durationMs == null
                ? ''
                : formatDuration(Duration(milliseconds: track.durationMs!)),
          ),
          _Fact('ISRC', track.isrc ?? ''),
          _Fact(l10n.songLanguage, track.language ?? ''),
          _Fact(l10n.songSource, track.extensionName),
          const SizedBox(height: AppTokens.space16),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: AppTokens.space8),
          Wrap(
            spacing: AppTokens.space8,
            runSpacing: AppTokens.space8,
            children: [
              FilledButton.icon(
                onPressed: _busy || !canPlay
                    ? null
                    : () => _run((song) => openSong(context, ref, song)),
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.songPlay),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run((song) async {
                        router.replace<void>('/song/${song.id}');
                      }),
                icon: const Icon(Icons.library_add_outlined),
                label: Text(l10n.songAddToLibrary),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !canPlay
                    ? null
                    : () => _run((song) async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await ref
                              .read(extensionServiceProvider)
                              .download(song);
                          ref.read(libraryRevisionProvider.notifier).bump();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(l10n.downloadDone(song.title)),
                            ),
                          );
                        } catch (error) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(l10n.downloadFailed('$error')),
                            ),
                          );
                        }
                      }),
                icon: const Icon(Icons.download_outlined),
                label: Text(l10n.downloadOffline),
              ),
            ],
          ),
          if (!canPlay) ...[
            const SizedBox(height: AppTokens.space8),
            Text(l10n.songNoAudioExtension, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
