// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/theme/app_tokens.dart';

/// Asks for a repository link (Mornye's add-repository dialog: it stays
/// open while the repository loads and says why it could not), then for
/// trust in its signing key (EXTENSIONS.md §7), and adds it.
Future<void> addRepository(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final preview = await showDialog<RepositoryPreview>(
    context: context,
    builder: (_) => const AddRepositoryDialog(),
  );
  if (preview == null || !context.mounted) return;
  final trusted = await showDialog<bool>(
    context: context,
    builder: (context) => _TrustDialog(preview: preview),
  );
  if (trusted != true) return;
  try {
    await ref.read(extensionsProvider.notifier).addRepository(preview);
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('$error')));
  }
}

/// The link field; pops with the checked [RepositoryPreview].
class AddRepositoryDialog extends ConsumerStatefulWidget {
  const AddRepositoryDialog({super.key});

  @override
  ConsumerState<AddRepositoryDialog> createState() =>
      _AddRepositoryDialogState();
}

class _AddRepositoryDialogState extends ConsumerState<AddRepositoryDialog> {
  final _url = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty || _checking) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(extensionServiceProvider)
          .previewRepository(url);
      if (mounted) Navigator.pop(context, preview);
    } catch (error) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = l10n.repositoryInvalid('$error');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.repositoryAdd),
      content: TextField(
        key: const ValueKey('repository-url-field'),
        controller: _url,
        autofocus: true,
        enabled: !_checking,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.link),
          labelText: l10n.repositoryUrl,
          hintText: 'https://…/index.json',
          helperText: _error == null ? l10n.repositoryUrlHelp : null,
          errorText: _error,
          errorMaxLines: 4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.repositoryAdd),
        ),
      ],
    );
  }
}

class _TrustDialog extends StatelessWidget {
  const _TrustDialog({required this.preview});

  final RepositoryPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.repositoryTrustTitle(preview.name)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview.url),
            const SizedBox(height: AppTokens.space8),
            Text(l10n.repositoryExtensions(preview.extensions)),
            const SizedBox(height: AppTokens.space16),
            Text(l10n.repositoryKey),
            SelectableText(
              preview.fingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: AppTokens.space16),
            Text(l10n.repositoryTrustBody),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.repositoryTrust),
        ),
      ],
    );
  }
}

/// Confirms and removes [repository]; extensions from it stay installed.
Future<void> removeRepository(
  BuildContext context,
  WidgetRef ref,
  ExtensionRepository repository,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.repositoryRemoveTitle(repository.name)),
      content: Text(l10n.repositoryRemoveBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.actionCancel),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.repositoryRemove),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref
        .read(extensionsProvider.notifier)
        .removeRepository(repository.url);
  }
}
