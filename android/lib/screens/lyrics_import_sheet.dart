import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Lyrics import: paste text or pick a `.txt`, `.lrc` (plain or
/// enhanced) or `.ttml` file. Chinese lines get pinyin automatically.
Future<void> showLyricsImportSheet(
  BuildContext context,
  WidgetRef ref,
  Song song, {
  String initialText = '',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => LyricsImportSheet(song: song, initialText: initialText),
);

class LyricsImportSheet extends ConsumerStatefulWidget {
  const LyricsImportSheet({
    super.key,
    required this.song,
    this.initialText = '',
  });

  final Song song;

  /// Text to start with, e.g. a shared `.lrc` file.
  final String initialText;

  @override
  ConsumerState<LyricsImportSheet> createState() => _LyricsImportSheetState();
}

class _LyricsImportSheetState extends ConsumerState<LyricsImportSheet> {
  late final _text = TextEditingController(text: widget.initialText);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['lrc', 'txt', 'ttml'],
    );
    if (files.isEmpty) return;
    final bytes = await files.first.readAsBytes();
    setState(() => _text.text = utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (_text.text.trim().isEmpty) {
      setState(() => _error = l10n.lyricsEmptyError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(libraryServicesProvider)
          .lyrics
          .importText(widget.song.id, _text.text);
      ref.read(libraryRevisionProvider.notifier).bump();
      final player = ref.read(playerProvider);
      if (player.song?.id == widget.song.id) {
        await ref.read(playerProvider.notifier).reloadLyrics();
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
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
            l10n.lyricsImportTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppTokens.space4),
          Text(
            l10n.lyricsImportHint,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppTokens.space12),
          TextField(
            controller: _text,
            minLines: 6,
            maxLines: 12,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: l10n.lyricsPasteLabel,
              alignLabelWithHint: true,
              errorText: _error,
            ),
          ),
          const SizedBox(height: AppTokens.space12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(l10n.lyricsChooseFile),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.actionSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
