import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/extension_provider.dart';
import 'package:kalao/services/external_links.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/extension_widgets.dart';
import 'package:kalao/widgets/settings_group.dart';

/// One installed extension: what it is and may reach, its settings and
/// buttons (FEATURES 5.3), health checks, debug log, enable and uninstall.
class ExtensionDetailScreen extends ConsumerStatefulWidget {
  const ExtensionDetailScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<ExtensionDetailScreen> createState() =>
      _ExtensionDetailScreenState();
}

class _ExtensionDetailScreenState extends ConsumerState<ExtensionDetailScreen> {
  String? _busyAction;
  bool _checking = false;
  List<ExtensionLogEntry>? _logs;

  ExtensionsController get _controller => ref.read(extensionsProvider.notifier);

  Future<void> _guard(Future<void> Function() run) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _action(ExtensionInfo extension, ExtensionSetting button) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyAction = button.key);
    try {
      final result = await _controller.runAction(extension, button, (
        url,
      ) async {
        await openExternalUrl(Uri.parse(url));
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result is String && result.isNotEmpty
                ? result
                : l10n.extensionActionDone(button.label),
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _health() async {
    setState(() => _checking = true);
    await _guard(() => _controller.checkHealth(widget.id));
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _loadLogs() async {
    final logs = await ref.read(extensionServiceProvider).logs(widget.id);
    if (mounted) setState(() => _logs = logs.reversed.toList());
  }

  Future<void> _uninstall(ExtensionInfo extension) async {
    final l10n = AppLocalizations.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.extensionUninstallTitle(extension.manifest.name)),
        content: Text(l10n.extensionUninstallBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.extensionUninstall),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _guard(() async {
      await _controller.uninstall(extension);
      router.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final extension = ref.watch(extensionsProvider).byId(widget.id);
    if (extension == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.extensionNotInstalled)),
      );
    }
    final manifest = extension.manifest;
    final status = extensionStatus(l10n, extension);
    final health = extension.health;
    return Scaffold(
      appBar: AppBar(title: Text(manifest.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTokens.space24),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    l10n.extensionVersion(manifest.version),
                    if (manifest.author.isNotEmpty) manifest.author,
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
                if (manifest.description.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.space8),
                  Text(manifest.description),
                ],
                if (manifest.homepage case final homepage?)
                  TextButton.icon(
                    onPressed: () => openExternalUrl(Uri.parse(homepage)),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(homepage),
                  ),
                if (status != null) ...[
                  const SizedBox(height: AppTokens.space8),
                  Text(
                    status,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (extension.lastError case final error?
                    when extension.degraded) ...[
                  const SizedBox(height: AppTokens.space4),
                  Text(error, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: AppTokens.space8),
                CapabilityChips(capabilities: manifest.capabilities),
              ],
            ),
          ),
          SwitchListTile(
            title: Text(l10n.extensionEnabled),
            value: extension.enabled,
            onChanged: (enabled) =>
                _guard(() => _controller.setEnabled(extension.id, enabled)),
          ),
          if (manifest.settings.isNotEmpty)
            SettingsGroup(
              title: l10n.extensionSettings,
              children: [
                ExtensionSettingsForm(
                  extension: extension,
                  busyAction: _busyAction,
                  onChanged: (setting, value) => _guard(
                    () => _controller.setSetting(extension, setting, value),
                  ),
                  onAction: (button) => _action(extension, button),
                ),
              ],
            ),
          SettingsGroup(
            title: l10n.extensionPermissions,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space16,
                  vertical: AppTokens.space8,
                ),
                child: HostList(manifest: manifest),
              ),
            ],
          ),
          if (manifest.healthChecks > 0)
            SettingsGroup(
              title: l10n.extensionHealth,
              children: [
                ListTile(
                  leading: Icon(
                    health == null
                        ? Icons.help_outline
                        : health.ok
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: health == null
                        ? null
                        : health.ok
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  title: Text(
                    health == null
                        ? l10n.extensionHealthUnknown
                        : health.ok
                        ? l10n.extensionHealthOk
                        : l10n.extensionHealthFailed,
                  ),
                  subtitle: health == null
                      ? null
                      : Text(
                          [
                            for (final check in health.checks)
                              '${check.id}: ${check.ok ? '${check.status} · ${check.latencyMs} ms' : check.error ?? '${check.status}'}',
                          ].join('\n'),
                        ),
                  trailing: _checking
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _health,
                          child: Text(l10n.extensionHealthCheck),
                        ),
                ),
              ],
            ),
          SettingsGroup(
            title: l10n.extensionAbout,
            children: [
              ListTile(
                title: Text(l10n.extensionSource),
                subtitle: Text(switch (extension.sourceKind) {
                  'repository' => extension.repository ?? '',
                  'folder' => l10n.extensionSourceFolder(
                    extension.folder ?? '',
                  ),
                  _ => l10n.extensionSourceFile,
                }),
                trailing: extension.sourceKind == 'folder'
                    ? IconButton(
                        tooltip: l10n.extensionReload,
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _guard(() async {
                          await _controller.installFolder(extension.folder!);
                        }),
                      )
                    : null,
              ),
              ListTile(
                title: Text(l10n.extensionFingerprint),
                subtitle: SelectableText(extension.sha256),
              ),
              ListTile(
                title: Text(l10n.extensionStorage),
                subtitle: Text(
                  l10n.extensionStorageBytes(extension.storageBytes),
                ),
              ),
              ExpansionTile(
                title: Text(l10n.extensionLog),
                onExpansionChanged: (open) {
                  if (open) _loadLogs();
                },
                children: [
                  if (_logs == null)
                    const LinearProgressIndicator()
                  else if (_logs!.isEmpty)
                    ListTile(title: Text(l10n.extensionLogEmpty))
                  else
                    for (final entry in _logs!.take(100))
                      ListTile(
                        dense: true,
                        title: Text(entry.message),
                        subtitle: Text('${entry.timestamp} · ${entry.level}'),
                      ),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(AppTokens.space16),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: () => _uninstall(extension),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.extensionUninstall),
            ),
          ),
        ],
      ),
    );
  }
}
