import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/models/extension.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:kalao/services/extension_service.dart';
import 'package:kalao/utils/logger.dart';

const _log = AppLogger('Extensions');

/// Secure storage in the app; tests override it with [MemorySecretStore].
final secretStoreProvider = Provider<SecretStore>(
  (ref) => const SecureSecretStore(),
);

final extensionServiceProvider = Provider<ExtensionService>((ref) {
  final services = ref.watch(libraryServicesProvider);
  return ExtensionService(
    storage: services.storage,
    library: services.library,
    importer: services.importer,
    secrets: ref.watch(secretStoreProvider),
  );
});

@immutable
class ExtensionsState {
  const ExtensionsState({
    this.extensions = const [],
    this.priority = const {},
    this.repositories = const [],
    this.loaded = false,
    this.error,
  });

  final List<ExtensionInfo> extensions;

  /// Capability name → extension ids in the user's order.
  final Map<String, List<String>> priority;
  final List<RepositoryListing> repositories;
  final bool loaded;
  final String? error;

  ExtensionInfo? byId(String id) {
    for (final extension in extensions) {
      if (extension.id == id) return extension;
    }
    return null;
  }

  /// Enabled extensions with [capability], in priority order.
  List<ExtensionInfo> providers(ExtensionCapability capability) => [
    for (final id in priority[capability.name] ?? const <String>[])
      if (byId(id) case final extension?
          when extension.enabled && extension.manifest.has(capability))
        extension,
  ];

  bool has(ExtensionCapability capability) => providers(capability).isNotEmpty;

  int get updates =>
      repositories.fold(0, (sum, listing) => sum + listing.updates);

  ExtensionsState copyWith({
    List<ExtensionInfo>? extensions,
    Map<String, List<String>>? priority,
    List<RepositoryListing>? repositories,
    bool? loaded,
    String? Function()? error,
  }) => ExtensionsState(
    extensions: extensions ?? this.extensions,
    priority: priority ?? this.priority,
    repositories: repositories ?? this.repositories,
    loaded: loaded ?? this.loaded,
    error: error != null ? error() : this.error,
  );
}

final extensionsProvider =
    NotifierProvider<ExtensionsController, ExtensionsState>(
      ExtensionsController.new,
    );

/// The installed extensions, their order and the repositories, for the
/// Extensions tab and every screen that offers extension results.
class ExtensionsController extends Notifier<ExtensionsState> {
  ExtensionService get _service => ref.read(extensionServiceProvider);

  @override
  ExtensionsState build() {
    ref.listen(
      settingsProvider.select((settings) => settings.extensionDeveloperMode),
      (_, enabled) => unawaited(_service.setDeveloperMode(enabled)),
    );
    Future.microtask(() async {
      await refresh();
      await _checkRepositoriesIfDue();
    });
    return const ExtensionsState();
  }

  static const _checkedKey = 'extension_repos_checked_at';

  /// Repositories are checked for updates once a day (EXTENSIONS.md §7);
  /// installing an update always waits for the user.
  Future<void> _checkRepositoriesIfDue() async {
    if (!ref.mounted || state.error != null) return;
    final preferences = ref.read(sharedPreferencesProvider);
    final last = DateTime.tryParse(preferences.getString(_checkedKey) ?? '');
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(days: 1)) return;
    await refreshRepositories();
    await preferences.setString(_checkedKey, now.toIso8601String());
  }

  /// Starts the manager (once) and reloads the list.
  Future<void> refresh() async {
    try {
      await _service.start(
        developerMode: ref.read(settingsProvider).extensionDeveloperMode,
      );
      final listed = await _service.list();
      if (!ref.mounted) return;
      state = state.copyWith(
        extensions: listed.extensions,
        priority: listed.priority,
        loaded: true,
        error: () => null,
      );
    } catch (error) {
      _log.w('Extensions unavailable', error);
      if (!ref.mounted) return;
      state = state.copyWith(loaded: true, error: () => '$error');
    }
  }

  /// Fetches every repository's index (updates and new extensions).
  Future<void> refreshRepositories() async {
    try {
      final repositories = await _service.refreshRepositories();
      if (!ref.mounted) return;
      state = state.copyWith(repositories: repositories);
    } catch (error) {
      _log.w('Repository refresh failed', error);
    }
  }

  Future<T> _change<T>(
    Future<T> Function(ExtensionService service) apply,
  ) async {
    try {
      return await apply(_service);
    } finally {
      if (ref.mounted) await refresh();
    }
  }

  Future<ExtensionInfo> installFile(
    String path, {
    bool allowDowngrade = false,
  }) => _change(
    (service) => service.install(path, allowDowngrade: allowDowngrade),
  );

  Future<ExtensionInfo> installFolder(String path) =>
      _change((service) => service.installFolder(path));

  Future<ExtensionInfo> installFromRepository(String url, String id) => _change(
    (service) async {
      final info = await service.installFromRepository(url, id);
      state = state.copyWith(repositories: await service.refreshRepositories());
      return info;
    },
  );

  Future<void> uninstall(ExtensionInfo extension) =>
      _change((service) => service.uninstall(extension));

  Future<void> setEnabled(String id, bool enabled) =>
      _change((service) => service.setEnabled(id, enabled));

  Future<void> setPriority(ExtensionCapability capability, List<String> ids) {
    // Show the new order at once.
    state = state.copyWith(priority: {...state.priority, capability.name: ids});
    return _change((service) => service.setPriority(capability, ids));
  }

  Future<void> setSetting(
    ExtensionInfo extension,
    ExtensionSetting setting,
    Object? value,
  ) => _change((service) => service.setSetting(extension, setting, value));

  Future<Object?> runAction(
    ExtensionInfo extension,
    ExtensionSetting button,
    Future<void> Function(String url) openUrl,
  ) => _change((service) => service.runAction(extension, button, openUrl));

  Future<ExtensionHealth> checkHealth(String id) =>
      _change((service) => service.checkHealth(id));

  Future<void> addRepository(RepositoryPreview preview) => _change((
    service,
  ) async {
    await service.addRepository(preview);
    state = state.copyWith(repositories: await service.refreshRepositories());
  });

  Future<void> removeRepository(String url) => _change((service) async {
    await service.removeRepository(url);
    state = state.copyWith(
      repositories: [
        for (final listing in state.repositories)
          if (listing.repository.url != url) listing,
      ],
    );
  });
}
