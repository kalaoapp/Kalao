import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/empty_state.dart';
import 'package:kalao/widgets/extension_widgets.dart';

/// The Extensions tab (FEATURES 5.x): installed extensions and the
/// repositories' store. Install from a file, order, repository management and
/// options are in Settings → Extensions.
class ExtensionsTab extends ConsumerWidget {
  const ExtensionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(extensionsProvider);
    final notifier = ref.read(extensionsProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navExtensions),
        actions: [
          IconButton(
            tooltip: l10n.extensionRepositories,
            icon: Badge(
              isLabelVisible: state.updates > 0,
              label: Text('${state.updates}'),
              child: const Icon(Icons.storefront_outlined),
            ),
            onPressed: () => context.push('/extensions/repositories'),
          ),
          IconButton(
            tooltip: l10n.settingsTitle,
            icon: const Icon(Icons.tune),
            onPressed: () => context.push('/settings/extensions'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await notifier.refresh();
          await notifier.refreshRepositories();
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppTokens.space24),
          children: [
            if (state.error case final error?)
              Padding(
                padding: const EdgeInsets.all(AppTokens.space16),
                child: Text(
                  l10n.extensionsUnavailable(error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!state.loaded)
              const LinearProgressIndicator()
            else if (state.extensions.isEmpty)
              EmptyState(
                icon: Icons.extension_outlined,
                title: l10n.extensionsEmptyTitle,
                body: l10n.extensionsEmptyBody,
              )
            else
              for (final extension in state.extensions)
                _ExtensionTile(extension: extension),
          ],
        ),
      ),
    );
  }
}

class _ExtensionTile extends ConsumerWidget {
  const _ExtensionTile({required this.extension});

  final ExtensionInfo extension;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final manifest = extension.manifest;
    final status = extensionStatus(l10n, extension);
    final attention =
        extension.degraded ||
        !extension.supported ||
        (extension.enabled && extension.missingSecrets.isNotEmpty);
    return ListTile(
      leading: CircleAvatar(
        child: Icon(
          manifest.capabilities.isEmpty
              ? Icons.extension_outlined
              : capabilityIcon(manifest.capabilities.first),
        ),
      ),
      title: Text(manifest.name),
      subtitle: Text(
        [
          l10n.extensionVersion(manifest.version),
          for (final capability in manifest.capabilities)
            capabilityLabel(l10n, capability),
          ?status,
        ].join(' · '),
        style: attention ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      trailing: Switch(
        value: extension.enabled,
        onChanged: (enabled) => ref
            .read(extensionsProvider.notifier)
            .setEnabled(extension.id, enabled),
      ),
      onTap: () => context.push('/extensions/detail/${extension.id}'),
    );
  }
}
