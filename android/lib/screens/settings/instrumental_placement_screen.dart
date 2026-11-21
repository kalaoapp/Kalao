import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/providers/library_folder_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/document_tree.dart';

/// Shows [InstrumentalPlacementScreen] unless the user has already chosen;
/// whether a choice is in place afterwards.
Future<bool> ensureInstrumentalPlacement(
  BuildContext context,
  WidgetRef ref,
) async {
  final placement = ref.read(settingsProvider).instrumentalPlacement;
  if (placement != InstrumentalPlacement.undecided) return true;
  final chosen = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const InstrumentalPlacementScreen(),
    ),
  );
  return chosen ?? false;
}

/// Where new instrumentals of music-folder songs go (FEATURES 6.8), asked
/// before the first music folder is added: in a separate folder the user
/// picks (outside every music folder), or next to each original. The
/// choice is saved and every later instrumental follows it.
class InstrumentalPlacementScreen extends ConsumerStatefulWidget {
  const InstrumentalPlacementScreen({super.key});

  @override
  ConsumerState<InstrumentalPlacementScreen> createState() =>
      _InstrumentalPlacementScreenState();
}

class _InstrumentalPlacementScreenState
    extends ConsumerState<InstrumentalPlacementScreen> {
  late InstrumentalPlacement _choice;
  String? _folder;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _choice = settings.instrumentalPlacement;
    _folder = settings.instrumentalFolderUri;
  }

  Future<void> _pickFolder() async {
    final l10n = AppLocalizations.of(context);
    final uri = await PlatformBridge.pickDocumentTree();
    if (uri == null || !mounted) return;
    final folders = ref.read(libraryFoldersProvider).folders;
    final overlapping = folders.where((f) => treesOverlap(f.treeUri, uri));
    setState(() {
      if (overlapping.isNotEmpty) {
        _error = l10n.placementOverlap(overlapping.first.name);
      } else {
        _error = null;
        _folder = uri;
        _choice = InstrumentalPlacement.separateFolder;
      }
    });
  }

  bool get _ready => switch (_choice) {
    InstrumentalPlacement.undecided => false,
    InstrumentalPlacement.separateFolder => _folder != null,
    InstrumentalPlacement.besideOriginal => true,
  };

  Future<void> _save() async {
    await ref
        .read(settingsProvider.notifier)
        .setInstrumentalPlacement(_choice, folderUri: _folder);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final folder = _folder;
    final decided =
        ref.watch(settingsProvider).instrumentalPlacement !=
        InstrumentalPlacement.undecided;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.actionCancel,
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space24,
            0,
            AppTokens.space24,
            AppTokens.space24,
          ),
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: AppTokens.space16),
            Text(l10n.placementTitle, style: theme.textTheme.headlineSmall),
            const SizedBox(height: AppTokens.space8),
            Text(
              l10n.placementBody,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (decided) ...[
              const SizedBox(height: AppTokens.space8),
              Text(l10n.placementChangeNote, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: AppTokens.space24),
            _Choice(
              key: const ValueKey('placement-separate'),
              icon: Icons.drive_folder_upload_outlined,
              title: l10n.placementSeparate,
              body: l10n.placementSeparateBody,
              selected: _choice == InstrumentalPlacement.separateFolder,
              onTap: _pickFolder,
              footer: folder == null
                  ? null
                  : Text(
                      l10n.placementFolder(treeFolderName(folder)),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.space8),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: AppTokens.space12),
            _Choice(
              key: const ValueKey('placement-beside'),
              icon: Icons.folder_copy_outlined,
              title: l10n.placementBeside,
              body: l10n.placementBesideBody,
              selected: _choice == InstrumentalPlacement.besideOriginal,
              onTap: () => setState(() {
                _choice = InstrumentalPlacement.besideOriginal;
                _error = null;
              }),
            ),
            const SizedBox(height: AppTokens.space24),
            FilledButton(
              onPressed: _ready ? _save : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: AppTokens.space16,
                ),
              ),
              child: Text(l10n.placementContinue),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: AppTokens.space16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: AppTokens.space4),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (footer case final footer?) ...[
                        const SizedBox(height: AppTokens.space8),
                        footer,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppTokens.space8),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
