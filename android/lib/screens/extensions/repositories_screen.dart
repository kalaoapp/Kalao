import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/screens/extensions/add_repository.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/app_page.dart';
import 'package:kalao/widgets/empty_state.dart';

/// Browse the trusted repositories (EXTENSIONS.md §7): install and update
/// their extensions. Settings → Extensions → Repositories manages the list.
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final listings = ref.watch(
      extensionsProvider.select((state) => state.repositories),
    );
    return AppPage(
      title: l10n.extensionRepositories,
      actions: [
        IconButton(
          tooltip: l10n.repositoryRefresh,
          icon: const Icon(Icons.refresh),
          onPressed: _refreshing ? null : _refresh,
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => addRepository(context, ref),
        icon: const Icon(Icons.add_link),
        label: Text(l10n.repositoryAdd),
      ),
      progress: _refreshing ? double.nan : null,
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
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.symmetric(
              horizontal: AppTokens.space16,
              vertical: AppTokens.space8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The repository itself, set apart from its extensions.
                ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(
                      listing.repository.name,
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle: Text(listing.repository.url),
                    trailing: IconButton(
                      tooltip: l10n.repositoryRemove,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          removeRepository(context, ref, listing.repository),
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (listing.error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.space16,
                      AppTokens.space8,
                      AppTokens.space16,
                      0,
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
                                  : () =>
                                        _install(listing.repository.url, entry),
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
    );
  }
}
