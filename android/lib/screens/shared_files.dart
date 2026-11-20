import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/screens/import_sheet.dart';
import 'package:kalao/screens/lyrics_import_sheet.dart';
import 'package:kalao/screens/settings/backup_screen.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/utils/logger.dart';
import 'package:kalao/widgets/song_widgets.dart';
import 'package:path/path.dart' as p;

const _log = AppLogger('SharedFiles');

/// What to do with files opened with or shared to Kalao.
enum SharedFilesAction { restore, importAudio, importLyrics, unsupported }

SharedFilesAction sharedFilesAction(List<String> names) {
  String ext(String name) =>
      p.extension(name).replaceFirst('.', '').toLowerCase();
  final kinds = names.map(ext).toSet();
  if (kinds.any(audioExtensions.contains)) return SharedFilesAction.importAudio;
  if (kinds.contains('kalaobackup')) return SharedFilesAction.restore;
  if (kinds.any(lyricsExtensions.contains)) {
    return SharedFilesAction.importLyrics;
  }
  return SharedFilesAction.unsupported;
}

/// Takes the files the host received and opens the matching flow: audio
/// (with any lyrics files) goes to the import pairing sheet, a backup to the
/// restore preview, lyrics alone to the lyrics sheet of a chosen song.
Future<void> handleSharedFiles(BuildContext context, WidgetRef ref) async {
  final List<({String path, String name})> files;
  try {
    files = await PlatformBridge.takeSharedFiles();
  } catch (error) {
    _log.w('Could not read shared files', error);
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    switch (sharedFilesAction([for (final f in files) f.name])) {
      case SharedFilesAction.importAudio:
        final picked = <ImportSource>[
          for (final file in files)
            (name: file.name, read: File(file.path).openRead),
        ];
        final count = await showModalBottomSheet<int>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          isDismissible: false,
          builder: (_) => ImportSheet(files: picked),
        );
        if (count != null && count > 0) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.importDone(count))),
          );
        }
      case SharedFilesAction.restore:
        final backup = files.firstWhere((f) => f.name.endsWith('.kalaobackup'));
        final staged = await restoreBackupFile(context, backup.path);
        if (context.mounted) await confirmRestore(context, staged);
      case SharedFilesAction.importLyrics:
        final text = utf8.decode(
          await File(files.first.path).readAsBytes(),
          allowMalformed: true,
        );
        if (!context.mounted) return;
        final song = await _chooseSong(context, ref);
        if (song != null && context.mounted) {
          await showLyricsImportSheet(context, ref, song, initialText: text);
        }
      case SharedFilesAction.unsupported:
        messenger.showSnackBar(SnackBar(content: Text(l10n.sharedUnsupported)));
    }
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('$error')));
  } finally {
    for (final file in files) {
      try {
        await File(file.path).delete();
      } on FileSystemException {
        // The import already moved or removed it.
      }
    }
  }
}

/// The song shared lyrics belong to: the current song first, then the
/// library by most recently added.
Future<Song?> _chooseSong(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final current = ref.read(playerProvider).song;
  final songs = await ref
      .read(libraryServicesProvider)
      .library
      .songs(sort: SongSort.recentlyAdded, limit: 200);
  final ordered = [?current, ...songs.where((s) => s.id != current?.id)];
  if (!context.mounted) return null;
  if (ordered.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.sharedLyricsNoSongs)));
    return null;
  }
  return showDialog<Song>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10n.sharedLyricsChooseSong),
      children: [
        for (final song in ordered)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, song),
            child: Row(
              children: [
                SongCover(song: song, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    song.artist.isEmpty
                        ? song.title
                        : '${song.title} · ${song.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
