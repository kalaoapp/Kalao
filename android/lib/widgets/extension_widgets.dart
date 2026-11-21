import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/theme/app_tokens.dart';

IconData capabilityIcon(ExtensionCapability capability) => switch (capability) {
  ExtensionCapability.lyrics => Icons.lyrics_outlined,
  ExtensionCapability.metadata => Icons.info_outline,
  ExtensionCapability.audio => Icons.music_note_outlined,
  ExtensionCapability.artwork => Icons.image_outlined,
};

String capabilityLabel(AppLocalizations l10n, ExtensionCapability capability) =>
    switch (capability) {
      ExtensionCapability.lyrics => l10n.capabilityLyrics,
      ExtensionCapability.metadata => l10n.capabilityMetadata,
      ExtensionCapability.audio => l10n.capabilityAudio,
      ExtensionCapability.artwork => l10n.capabilityArtwork,
    };

class CapabilityChips extends StatelessWidget {
  const CapabilityChips({super.key, required this.capabilities});

  final List<ExtensionCapability> capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space4,
      children: [
        for (final capability in capabilities)
          Chip(
            avatar: Icon(capabilityIcon(capability), size: 18),
            label: Text(capabilityLabel(l10n, capability)),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// The complete list of hosts the extension may reach; hosts that a
/// setting unlocks say so.
class HostList extends StatelessWidget {
  const HostList({super.key, required this.manifest});

  final ExtensionManifest manifest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unlockedBy = {
      for (final setting in manifest.settings)
        ?setting.grantsNetwork: setting.label,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.extensionHosts, style: theme.textTheme.titleSmall),
        const SizedBox(height: AppTokens.space4),
        if (manifest.hosts.isEmpty)
          Text(l10n.extensionNoHosts)
        else
          for (final host in manifest.hosts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.public, size: 18),
                  const SizedBox(width: AppTokens.space8),
                  Expanded(
                    child: Text(
                      unlockedBy[host] == null
                          ? host
                          : l10n.extensionHostAfter(host, unlockedBy[host]!),
                    ),
                  ),
                ],
              ),
            ),
        if (manifest.callbackPath != null) ...[
          const SizedBox(height: AppTokens.space4),
          Text(l10n.extensionLogin, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// The settings form generated from the manifest (FEATURES 5.3). Secrets
/// are never shown; [onChanged] and [onAction] run the change.
class ExtensionSettingsForm extends StatelessWidget {
  const ExtensionSettingsForm({
    super.key,
    required this.extension,
    required this.onChanged,
    required this.onAction,
    this.busyAction,
  });

  final ExtensionInfo extension;
  final Future<void> Function(ExtensionSetting setting, Object? value)
  onChanged;
  final Future<void> Function(ExtensionSetting button) onAction;

  /// The button whose action is running.
  final String? busyAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        for (final setting in extension.manifest.settings)
          switch (setting.type) {
            ExtensionSettingType.toggle => SwitchListTile(
              title: Text(setting.label),
              subtitle: setting.description == null
                  ? null
                  : Text(setting.description!),
              value: extension.value(setting) == true,
              onChanged: (value) => onChanged(setting, value),
            ),
            ExtensionSettingType.select => ListTile(
              title: Text(setting.label),
              subtitle: Text('${extension.value(setting) ?? '—'}'),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: Text(setting.label),
                    children: [
                      RadioGroup<String>(
                        groupValue: '${extension.value(setting)}',
                        onChanged: (value) => Navigator.pop(context, value),
                        child: Column(
                          children: [
                            for (final option in setting.options)
                              RadioListTile<String>(
                                value: option,
                                title: Text(option),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
                if (picked != null) await onChanged(setting, picked);
              },
            ),
            ExtensionSettingType.button => ListTile(
              title: Text(setting.label),
              subtitle: setting.description == null
                  ? null
                  : Text(setting.description!),
              trailing: busyAction == setting.key
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.tonal(
                      onPressed: busyAction == null
                          ? () => onAction(setting)
                          : null,
                      child: Text(l10n.extensionRun),
                    ),
            ),
            ExtensionSettingType.secret => ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(setting.label),
              subtitle: Text(
                extension.secretsSet.contains(setting.key)
                    ? l10n.extensionSecretSet
                    : l10n.extensionSecretMissing,
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final value = await _editText(
                  context,
                  setting,
                  '',
                  secret: true,
                );
                if (value != null) await onChanged(setting, value);
              },
            ),
            ExtensionSettingType.text ||
            ExtensionSettingType.number => ListTile(
              title: Text(setting.label),
              subtitle: Text(
                '${extension.value(setting) ?? setting.description ?? '—'}',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () async {
                final value = await _editText(
                  context,
                  setting,
                  '${extension.value(setting) ?? ''}',
                );
                if (value == null) return;
                if (setting.type == ExtensionSettingType.number) {
                  final number = num.tryParse(value);
                  await onChanged(setting, value.isEmpty ? null : number);
                } else {
                  await onChanged(setting, value.isEmpty ? null : value);
                }
              },
            ),
          },
      ],
    );
  }

  Future<String?> _editText(
    BuildContext context,
    ExtensionSetting setting,
    String initial, {
    bool secret = false,
  }) => showDialog<String>(
    context: context,
    builder: (context) =>
        _TextSettingDialog(setting: setting, initial: initial, secret: secret),
  );
}

class _TextSettingDialog extends StatefulWidget {
  const _TextSettingDialog({
    required this.setting,
    required this.initial,
    required this.secret,
  });

  final ExtensionSetting setting;
  final String initial;
  final bool secret;

  @override
  State<_TextSettingDialog> createState() => _TextSettingDialogState();
}

class _TextSettingDialogState extends State<_TextSettingDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final number = widget.setting.type == ExtensionSettingType.number;
    return AlertDialog(
      title: Text(widget.setting.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.secret,
            enableSuggestions: !widget.secret,
            autocorrect: false,
            keyboardType: number
                ? const TextInputType.numberWithOptions(decimal: true)
                : null,
            inputFormatters: number
                ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))]
                : null,
            decoration: InputDecoration(helperText: widget.setting.description),
          ),
          if (widget.secret) ...[
            const SizedBox(height: AppTokens.space8),
            Text(l10n.extensionSecretNote),
          ],
        ],
      ),
      actions: [
        if (widget.secret)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(l10n.extensionSecretClear),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.actionSave),
        ),
      ],
    );
  }
}

/// One line about what needs attention: disabled, degraded, a missing
/// secret, or nothing.
String? extensionStatus(AppLocalizations l10n, ExtensionInfo extension) {
  if (!extension.supported) {
    return l10n.extensionNeedsNewer(extension.manifest.minKalao ?? '');
  }
  if (!extension.enabled) return l10n.extensionDisabled;
  if (extension.degraded) return l10n.extensionDegraded;
  if (extension.missingSecrets.isNotEmpty) return l10n.extensionNeedsSecret;
  return null;
}
