// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/screens/extensions/add_repository.dart';
import 'package:kalao/widgets/app_sliver_header.dart';
import 'package:kalao/widgets/settings_group.dart';

/// The trusted repositories, as Mornye's Repositories page: each row names
/// the repository, its link and its extension count or why it did not
/// load, with a remove button. A last group adds another repository.
class RepositorySettingsScreen extends ConsumerWidget {
  const RepositorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listings = ref.watch(
      extensionsProvider.select((state) => state.repositories),
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.extensionRepositories),
          if (listings.isNotEmpty)
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  for (final (index, listing) in listings.indexed)
                    SettingsItem(
                      key: ValueKey('repository-${listing.repository.url}'),
                      title: listing.repository.name,
                      subtitle: listing.repository.url,
                      showDivider: index < listings.length - 1,
                      footer: Text(
                        listing.error ??
                            l10n.repositoryExtensions(listing.entries.length),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: listing.error == null
                              ? scheme.onSurfaceVariant
                              : scheme.error,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: l10n.repositoryRemove,
                        icon: Icon(
                          Icons.remove_circle_outline,
                          color: scheme.error,
                        ),
                        onPressed: () =>
                            removeRepository(context, ref, listing.repository),
                      ),
                    ),
                ],
              ),
            ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  key: const ValueKey('repository-add'),
                  icon: Icons.add,
                  iconColor: scheme.primary,
                  title: l10n.repositoryAdd,
                  trailing: const SizedBox.shrink(),
                  showDivider: false,
                  onTap: () => addRepository(context, ref),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}
