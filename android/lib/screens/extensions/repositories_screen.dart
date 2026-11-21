import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';

/// Extension repositories (EXTENSIONS.md §7): add one by URL after
/// checking its key fingerprint, then install and update from it.
class RepositoriesScreen extends ConsumerStatefulWidget {
  const RepositoriesScreen({super.key});

  @override
  ConsumerState<RepositoriesScreen> createState() => _RepositoriesScreenState();
}

class _RepositoriesScreenState extends ConsumerState<RepositoriesScreen> {
  bool _refreshing = false;
  final _installing = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await ref.read(extensionsProvider.notifier).refreshRepositories();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _UrlDialog(),
    );
    if (url == null || url.isEmpty || !mounted) return;
    final RepositoryPreview preview;
    try {
      preview = await ref.read(extensionServiceProvider).previewRepository(url);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.repositoryInvalid('$error'))),
      );
      return;
    }
    if (!mounted) return;
    final trusted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.repositoryTrustTitle(preview.name)),
        content: Column(
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
      ),
    );
    if (trusted != true) return;
    try {
      await ref.read(extensionsProvider.notifier).addRepository(preview);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _install(String url, RepositoryEntry entry) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _installing.add(entry.id));
    try {
      final info = await ref
          .read(extensionsProvider.notifier)
          .installFromRepository(url, entry.id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.extensionInstalled(info.manifest.name))),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.extensionInstallFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _installing.remove(entry.id));
    }
  }

  Future<void> _remove(ExtensionRepository repository) async {
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
          FilledButton(
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final listings = ref.watch(
      extensionsProvider.select((state) => state.repositories),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.extensionRepositories),
        actions: [
          IconButton(
            tooltip: l10n.repositoryRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_link),
        label: Text(l10n.repositoryAdd),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (_refreshing) const LinearProgressIndicator(),
          if (listings.isEmpty && !_refreshing)
            EmptyState(
              icon: Icons.storefront_outlined,
              title: l10n.repositoryEmptyTitle,
              body: l10n.repositoryEmptyBody,
            ),
          for (final listing in listings)
            Card(
              margin: const EdgeInsets.symmetric(
                horizontal: AppTokens.space16,
                vertical: AppTokens.space8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: Text(listing.repository.name),
                    subtitle: Text(listing.repository.url),
                    trailing: IconButton(
                      tooltip: l10n.repositoryRemove,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(listing.repository),
                    ),
                  ),
                  if (listing.error case final error?)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.space16,
                      ),
                      child: Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  for (final entry in listing.entries)
                    ListTile(
                      title: Text(entry.name ?? entry.id),
                      subtitle: Text(
                        [
                          l10n.extensionVersion(entry.version),
                          if (entry.installedVersion case final installed?)
                            l10n.extensionInstalledVersion(installed),
                          if (entry.description case final description?
                              when description.isNotEmpty)
                            description,
                        ].join(' · '),
                      ),
                      trailing: _installing.contains(entry.id)
                          ? const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : switch (entry.status) {
                              RepositoryEntryStatus.installed => const Icon(
                                Icons.check,
                              ),
                              RepositoryEntryStatus.update => FilledButton(
                                onPressed: listing.repository.keyChanged
                                    ? null
                                    : () => _install(
                                        listing.repository.url,
                                        entry,
                                      ),
                                child: Text(l10n.extensionUpdate),
                              ),
                              RepositoryEntryStatus.available =>
                                FilledButton.tonal(
                                  onPressed: listing.repository.keyChanged
                                      ? null
                                      : () => _install(
                                          listing.repository.url,
                                          entry,
                                        ),
                                  child: Text(l10n.extensionInstall),
                                ),
                            },
                    ),
                  const SizedBox(height: AppTokens.space8),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _url = TextEditingController(text: 'https://');

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.repositoryAdd),
      content: TextField(
        controller: _url,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: l10n.repositoryUrl,
          helperText: l10n.repositoryUrlHelp,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _url.text.trim()),
          child: Text(l10n.repositoryCheck),
        ),
      ],
    );
  }
}
