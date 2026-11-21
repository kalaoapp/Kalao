import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/extension_widgets.dart';

/// The order extensions are asked in, per capability (FEATURES 5.4; the
/// roles of Mornye's lyrics and metadata provider priority pages). The
/// order breaks ties between equally good results and decides which
/// extension plays and draws artwork first.
class ProviderPriorityScreen extends ConsumerWidget {
  const ProviderPriorityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return DefaultTabController(
      length: ExtensionCapability.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.extensionPriority),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              for (final capability in ExtensionCapability.values)
                Tab(
                  icon: Icon(capabilityIcon(capability)),
                  text: capabilityLabel(l10n, capability),
                ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final capability in ExtensionCapability.values)
              _PriorityList(capability: capability),
          ],
        ),
      ),
    );
  }
}

class _PriorityList extends ConsumerWidget {
  const _PriorityList({required this.capability});

  final ExtensionCapability capability;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(extensionsProvider);
    final ids = [
      for (final id in state.priority[capability.name] ?? const <String>[])
        if (state.byId(id) != null) id,
    ];
    if (ids.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Text(l10n.extensionPriorityEmpty, textAlign: TextAlign.center),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTokens.space16),
          child: Text(l10n.extensionPriorityBody),
        ),
        Expanded(
          child: ReorderableListView(
            onReorderItem: (from, to) {
              final next = [...ids];
              final moved = next.removeAt(from);
              next.insert(to, moved);
              ref
                  .read(extensionsProvider.notifier)
                  .setPriority(capability, next);
            },
            children: [
              for (final (index, id) in ids.indexed)
                ListTile(
                  key: ValueKey(id),
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(state.byId(id)!.manifest.name),
                  subtitle: state.byId(id)!.enabled
                      ? null
                      : Text(l10n.extensionDisabled),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_handle,
                      semanticLabel: l10n.extensionPriorityDrag,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
