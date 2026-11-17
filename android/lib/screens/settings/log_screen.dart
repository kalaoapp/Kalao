// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/services/platform_bridge.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Dart log entries merged with the Rust log buffer, newest last. Nothing is
/// sent anywhere; the user can copy the text into a bug report.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<LogEntry> _native = const [];

  @override
  void initState() {
    super.initState();
    LogBuffer().addListener(_changed);
    _loadNative();
  }

  @override
  void dispose() {
    LogBuffer().removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadNative() async {
    try {
      final page = await PlatformBridge.getLogs();
      final today = DateTime.now();
      final entries = [
        for (final entry in page.entries) _fromNative(entry, today),
      ];
      if (mounted) setState(() => _native = entries);
    } catch (_) {
      // The engine is unavailable (for example in widget tests).
    }
  }

  static LogEntry _fromNative(NativeLogEntry entry, DateTime day) {
    // Rust stamps entries as HH:MM:SS.mmm local time.
    final parts = entry.timestamp.split(RegExp('[:.]'));
    int part(int index) =>
        index < parts.length ? int.tryParse(parts[index]) ?? 0 : 0;
    return LogEntry(
      timestamp: DateTime(
        day.year,
        day.month,
        day.day,
        part(0),
        part(1),
        part(2),
        part(3),
      ),
      level: switch (entry.level) {
        'DEBUG' => LogLevel.debug,
        'WARN' => LogLevel.warn,
        'ERROR' || 'FATAL' => LogLevel.error,
        _ => LogLevel.info,
      },
      tag: entry.tag,
      message: entry.message,
      isFromNative: true,
    );
  }

  List<LogEntry> get _entries =>
      [...LogBuffer().entries, ..._native]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: formatLogEntries(_entries)));
    messenger.showSnackBar(SnackBar(content: Text(l10n.logsCopied)));
  }

  /// Writes the log to a text file and opens the share sheet (M4.8).
  Future<void> _share() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.]'), '-')
        .substring(0, 19);
    final file = File(
      p.join(Directory.systemTemp.path, 'kalao-log-$stamp.txt'),
    );
    await file.writeAsString(formatLogEntries(_entries));
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'text/plain')]),
    );
  }

  Future<void> _clear() async {
    LogBuffer().clear();
    try {
      await PlatformBridge.clearLogs();
    } catch (_) {}
    if (mounted) setState(() => _native = const []);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.logsTitle),
        actions: [
          IconButton(
            tooltip: l10n.logsCopy,
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: entries.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: l10n.logsShare,
            icon: const Icon(Icons.share_outlined),
            onPressed: entries.isEmpty ? null : _share,
          ),
          IconButton(
            tooltip: l10n.logsClear,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: entries.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(child: Text(l10n.logsEmpty))
          : RefreshIndicator(
              onRefresh: _loadNative,
              child: ListView.separated(
                padding: const EdgeInsets.all(AppTokens.space12),
                itemCount: entries.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppTokens.space4),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final color = switch (entry.level) {
                    LogLevel.error => theme.colorScheme.error,
                    LogLevel.warn => theme.colorScheme.tertiary,
                    _ => theme.colorScheme.onSurfaceVariant,
                  };
                  return SelectableText(
                    entry.toString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: color,
                    ),
                  );
                },
              ),
            ),
    );
  }
}
