import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('ImportSheet');

/// Picks audio (and optional `.lrc`/`.txt`) files, stages them and opens the
/// pairing sheet. Returns the number of songs imported.
Future<int> pickAndImport(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.pickFiles(dialogTitle: l10n.importPickTitle);
  final usable = picked.where((file) {
    final ext = (file.extension ?? '').toLowerCase();
    return audioExtensions.contains(ext) || lyricsExtensions.contains(ext);
  }).toList();
  if (usable.isEmpty) {
    if (picked.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.importNoAudio)));
    }
    return 0;
  }
  if (!context.mounted) return 0;
  final count = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    isDismissible: false,
    builder: (_) => ImportSheet(
      files: [
        for (final file in usable)
          (name: file.name, read: file.readAsByteStream),
      ],
    ),
  );
  if (count != null && count > 0) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.importDone(count))));
  }
  return count ?? 0;
}

/// Pairing sheet: one card per proposed song with its instrumental and
/// lyrics file; the user can change titles, pairings and what to import.
class ImportSheet extends ConsumerStatefulWidget {
  const ImportSheet({super.key, required this.files});

  /// Picked or shared files: a name and a way to read the bytes.
  final List<ImportSource> files;

  @override
  ConsumerState<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<ImportSheet> {
  List<StagedFile> _staged = const [];
  List<ImportProposal>? _proposals;
  String? _error;
  bool _importing = false;

  ImportService get _importer => ref.read(libraryServicesProvider).importer;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final requestId = 'stage-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await PlatformBridge.startBackgroundWork(
        kind: 'import',
        title: 'Kalao',
        text: widget.files.length.toString(),
      );
      final staged = <StagedFile>[];
      for (final file in widget.files) {
        staged.add(await _importer.stage(file.name, file.read()));
      }
      final proposals = await _importer.propose(staged);
      if (mounted) {
        setState(() {
          _staged = staged;
          _proposals = proposals;
        });
      }
    } catch (error, stack) {
      _log.e('Import preparation failed ($requestId)', error, stack);
      if (mounted) setState(() => _error = '$error');
    } finally {
      await _stopWork();
    }
  }

  Future<void> _stopWork() async {
    try {
      await PlatformBridge.stopBackgroundWork('import');
    } catch (_) {}
  }

  Future<void> _import() async {
    final proposals = _proposals;
    if (proposals == null) return;
    setState(() => _importing = true);
    try {
      await PlatformBridge.startBackgroundWork(kind: 'import', title: 'Kalao');
      final ids = await _importer.commit(proposals);
      ref.read(libraryRevisionProvider.notifier).bump();
      if (mounted) Navigator.pop(context, ids.length);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _importing = false;
        });
      }
    } finally {
      await _stopWork();
    }
  }

  Future<void> _cancel() async {
    await _importer.discardStaging();
    if (mounted) Navigator.pop(context, 0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final proposals = _proposals;
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.space16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.importTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: _importing ? null : _cancel,
                  child: Text(l10n.actionCancel),
                ),
                const SizedBox(width: AppTokens.space8),
                FilledButton(
                  onPressed:
                      proposals == null ||
                          _importing ||
                          !proposals.any((p) => p.include)
                      ? null
                      : _import,
                  child: Text(l10n.importAction),
                ),
              ],
            ),
          ),
          if (_importing || (proposals == null && _error == null))
            Padding(
              padding: const EdgeInsets.all(AppTokens.space16),
              child: Semantics(
                label: _importing ? l10n.importWorking : l10n.importPreparing,
                child: const LinearProgressIndicator(),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(AppTokens.space16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (proposals != null)
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(AppTokens.space16),
                children: [
                  Text(l10n.importHint, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: AppTokens.space12),
                  for (final proposal in proposals)
                    _ProposalCard(
                      proposal: proposal,
                      audio: _staged
                          .where(
                            (file) => file.isAudio && file != proposal.original,
                          )
                          .toList(),
                      lyrics: _staged.where((file) => file.isLyrics).toList(),
                      onChanged: () => setState(() {}),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.audio,
    required this.lyrics,
    required this.onChanged,
  });

  final ImportProposal proposal;
  final List<StagedFile> audio;
  final List<StagedFile> lyrics;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.space12),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: proposal.include,
              onChanged: (value) {
                proposal.include = value ?? false;
                onChanged();
              },
              title: Text(
                proposal.original.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: proposal.duplicateOf != null
                  ? Text(
                      l10n.importDuplicate,
                      style: TextStyle(color: theme.colorScheme.tertiary),
                    )
                  : null,
            ),
            TextFormField(
              initialValue: proposal.title,
              decoration: InputDecoration(labelText: l10n.songTitle),
              onChanged: (value) => proposal.title = value,
            ),
            const SizedBox(height: AppTokens.space8),
            TextFormField(
              initialValue: proposal.artist,
              decoration: InputDecoration(labelText: l10n.songArtist),
              onChanged: (value) => proposal.artist = value,
            ),
            const SizedBox(height: AppTokens.space8),
            DropdownButtonFormField<StagedFile?>(
              initialValue: proposal.instrumental,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.importInstrumental),
              items: [
                DropdownMenuItem(value: null, child: Text(l10n.importNone)),
                for (final file in audio)
                  DropdownMenuItem(
                    value: file,
                    child: Text(file.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                proposal.instrumental = value;
                onChanged();
              },
            ),
            const SizedBox(height: AppTokens.space8),
            DropdownButtonFormField<StagedFile?>(
              initialValue: proposal.lyrics,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.importLyricsFile),
              items: [
                DropdownMenuItem(value: null, child: Text(l10n.importNone)),
                for (final file in lyrics)
                  DropdownMenuItem(
                    value: file,
                    child: Text(file.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                proposal.lyrics = value;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}
