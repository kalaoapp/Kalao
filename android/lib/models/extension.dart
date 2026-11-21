import 'package:flutter/foundation.dart';

/// What an extension provides (EXTENSIONS.md §1).
enum ExtensionCapability { lyrics, metadata, audio, artwork }

/// Manifest setting types (EXTENSIONS.md §3).
enum ExtensionSettingType { text, secret, toggle, select, number, button }

List<String> _strings(Object? value) => [
  for (final item in value as List<dynamic>? ?? const []) '$item',
];

Map<String, dynamic> _map(Object? value) =>
    (value as Map?)?.cast<String, dynamic>() ?? const {};

/// One setting the manifest declares; the settings form is built from these.
@immutable
class ExtensionSetting {
  const ExtensionSetting({
    required this.key,
    required this.type,
    required this.label,
    this.description,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.grantsNetwork,
    this.action,
  });

  factory ExtensionSetting.fromJson(Map<String, dynamic> json) =>
      ExtensionSetting(
        key: json['key'] as String? ?? '',
        type:
            ExtensionSettingType.values.asNameMap()[json['type']] ??
            ExtensionSettingType.text,
        label: json['label'] as String? ?? '',
        description: json['description'] as String?,
        defaultValue: json['default'],
        options: _strings(json['options']),
        min: (json['min'] as num?)?.toDouble(),
        max: (json['max'] as num?)?.toDouble(),
        grantsNetwork: json['grantsNetwork'] as String?,
        action: json['action'] as String?,
      );

  final String key;
  final ExtensionSettingType type;
  final String label;
  final String? description;
  final Object? defaultValue;
  final List<String> options;
  final double? min;
  final double? max;

  /// A host enabled once this setting has a value.
  final String? grantsNetwork;
  final String? action;

  bool get isSecret => type == ExtensionSettingType.secret;
}

@immutable
class ExtensionManifest {
  const ExtensionManifest({
    required this.id,
    required this.name,
    required this.version,
    this.minKalao,
    this.author = '',
    this.description = '',
    this.homepage,
    this.capabilities = const [],
    this.languages = const [],
    this.hosts = const [],
    this.settings = const [],
    this.callbackPath,
    this.healthChecks = 0,
  });

  factory ExtensionManifest.fromJson(Map<String, dynamic> json) =>
      ExtensionManifest(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        minKalao: json['minKalao'] as String?,
        author: json['author'] as String? ?? '',
        description: json['description'] as String? ?? '',
        homepage: json['homepage'] as String?,
        capabilities: [
          for (final name in _strings(json['capabilities']))
            ?ExtensionCapability.values.asNameMap()[name],
        ],
        languages: _strings(json['languages']),
        hosts: _strings(_map(json['network'])['hosts']),
        settings: [
          for (final setting in json['settings'] as List<dynamic>? ?? const [])
            ExtensionSetting.fromJson((setting as Map).cast()),
        ],
        callbackPath: _map(json['auth'])['callbackPath'] as String?,
        healthChecks: (json['health'] as List<dynamic>?)?.length ?? 0,
      );

  final String id;
  final String name;
  final String version;
  final String? minKalao;
  final String author;
  final String description;
  final String? homepage;
  final List<ExtensionCapability> capabilities;
  final List<String> languages;

  /// The complete list of hosts `kalao.fetch` may reach.
  final List<String> hosts;
  final List<ExtensionSetting> settings;
  final String? callbackPath;
  final int healthChecks;

  bool has(ExtensionCapability capability) => capabilities.contains(capability);

  List<ExtensionSetting> get secretSettings => [
    for (final setting in settings)
      if (setting.isSecret) setting,
  ];
}

/// The last health check (EXTENSIONS.md §3 `health`).
@immutable
class ExtensionHealth {
  const ExtensionHealth({
    required this.ok,
    this.checkedAt,
    this.checks = const [],
  });

  factory ExtensionHealth.fromJson(Map<String, dynamic> json) =>
      ExtensionHealth(
        ok: json['ok'] as bool? ?? false,
        checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
        checks: [
          for (final check in json['checks'] as List<dynamic>? ?? const [])
            (
              id: (check as Map)['id'] as String? ?? '',
              ok: check['ok'] as bool? ?? false,
              status: (check['status'] as num?)?.toInt(),
              error: check['error'] as String?,
              latencyMs: (check['latencyMs'] as num?)?.toInt() ?? 0,
            ),
        ],
      );

  final bool ok;
  final DateTime? checkedAt;
  final List<({String id, bool ok, int? status, String? error, int latencyMs})>
  checks;
}

/// An installed extension as `listExtensions` reports it.
@immutable
class ExtensionInfo {
  const ExtensionInfo({
    required this.manifest,
    this.enabled = true,
    this.sourceKind = 'file',
    this.repository,
    this.folder,
    this.sha256 = '',
    this.packagePath = '',
    this.settings = const {},
    this.secretsSet = const [],
    this.missingSecrets = const [],
    this.degraded = false,
    this.lastError,
    this.health,
    this.supported = true,
    this.storageBytes = 0,
    this.updatedAt,
  });

  factory ExtensionInfo.fromJson(Map<String, dynamic> json) {
    final source = _map(json['source']);
    return ExtensionInfo(
      manifest: ExtensionManifest.fromJson(_map(json['manifest'])),
      enabled: json['enabled'] as bool? ?? true,
      sourceKind: source['kind'] as String? ?? 'file',
      repository: source['repository'] as String?,
      folder: source['path'] as String?,
      sha256: json['sha256'] as String? ?? '',
      packagePath: json['packagePath'] as String? ?? '',
      settings: _map(json['settings']),
      secretsSet: _strings(json['secretsSet']),
      missingSecrets: _strings(json['missingSecrets']),
      degraded: json['degraded'] as bool? ?? false,
      lastError: json['lastError'] as String?,
      health: json['health'] is Map
          ? ExtensionHealth.fromJson(_map(json['health']))
          : null,
      supported: json['supported'] as bool? ?? true,
      storageBytes: (json['storageBytes'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  final ExtensionManifest manifest;
  final bool enabled;

  /// `file`, `repository` or `folder` (developer mode).
  final String sourceKind;
  final String? repository;
  final String? folder;
  final String sha256;
  final String packagePath;

  /// Plain (non-secret) setting values.
  final Map<String, dynamic> settings;
  final List<String> secretsSet;

  /// Secret settings without a value (asked for again after a restore).
  final List<String> missingSecrets;
  final bool degraded;
  final String? lastError;
  final ExtensionHealth? health;
  final bool supported;
  final int storageBytes;
  final DateTime? updatedAt;

  String get id => manifest.id;

  Object? value(ExtensionSetting setting) =>
      settings[setting.key] ?? setting.defaultValue;
}

/// What the install prompt shows (`inspectExtensionPackage`).
@immutable
class ExtensionPackagePreview {
  const ExtensionPackagePreview({
    required this.manifest,
    required this.sha256,
    this.bytes = 0,
    this.installedVersion,
    this.isUpdate = false,
    this.isDowngrade = false,
    this.isReinstall = false,
    this.supported = true,
    this.verifiedBy,
  });

  factory ExtensionPackagePreview.fromJson(Map<String, dynamic> json) =>
      ExtensionPackagePreview(
        manifest: ExtensionManifest.fromJson(_map(json['manifest'])),
        sha256: json['sha256'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        installedVersion: json['installedVersion'] as String?,
        isUpdate: json['isUpdate'] as bool? ?? false,
        isDowngrade: json['isDowngrade'] as bool? ?? false,
        isReinstall: json['isReinstall'] as bool? ?? false,
        supported: json['supported'] as bool? ?? true,
        verifiedBy: json['verifiedBy'] as String?,
      );

  final ExtensionManifest manifest;
  final String sha256;
  final int bytes;
  final String? installedVersion;
  final bool isUpdate;
  final bool isDowngrade;
  final bool isReinstall;

  /// The app is new enough (`minKalao`).
  final bool supported;

  /// The trusted repository that lists exactly this package, if any.
  final String? verifiedBy;

  /// The fingerprint as shown: groups of four hex digits.
  String get fingerprint => [
    for (var i = 0; i + 4 <= sha256.length && i < 32; i += 4)
      sha256.substring(i, i + 4),
  ].join(' ');
}

@immutable
class ExtensionRepository {
  const ExtensionRepository({
    required this.url,
    required this.name,
    required this.publicKey,
    this.checkedAt,
    this.keyChanged = false,
  });

  factory ExtensionRepository.fromJson(Map<String, dynamic> json) =>
      ExtensionRepository(
        url: json['url'] as String? ?? '',
        name: json['name'] as String? ?? '',
        publicKey: json['publicKey'] as String? ?? '',
        checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
        keyChanged: json['keyChanged'] as bool? ?? false,
      );

  final String url;
  final String name;
  final String publicKey;
  final DateTime? checkedAt;
  final bool keyChanged;

  Map<String, Object?> toJson() => {
    'url': url,
    'name': name,
    'publicKey': publicKey,
  };
}

enum RepositoryEntryStatus { available, installed, update }

/// One extension a repository offers, with its state on this device.
@immutable
class RepositoryEntry {
  const RepositoryEntry({
    required this.id,
    required this.version,
    this.name,
    this.description,
    this.capabilities = const [],
    this.installedVersion,
    this.status = RepositoryEntryStatus.available,
  });

  factory RepositoryEntry.fromJson(Map<String, dynamic> json) {
    final entry = _map(json['entry']);
    return RepositoryEntry(
      id: entry['id'] as String? ?? '',
      version: entry['version'] as String? ?? '',
      name: entry['name'] as String?,
      description: entry['description'] as String?,
      capabilities: _strings(entry['capabilities']),
      installedVersion: json['installedVersion'] as String?,
      status:
          RepositoryEntryStatus.values.asNameMap()[json['status']] ??
          RepositoryEntryStatus.available,
    );
  }

  final String id;
  final String version;
  final String? name;
  final String? description;
  final List<String> capabilities;
  final String? installedVersion;
  final RepositoryEntryStatus status;
}

/// A refreshed repository: what it offers, or why it could not be read.
@immutable
class RepositoryListing {
  const RepositoryListing({
    required this.repository,
    this.entries = const [],
    this.error,
  });

  factory RepositoryListing.fromJson(Map<String, dynamic> json) =>
      RepositoryListing(
        repository: ExtensionRepository.fromJson(_map(json['repository'])),
        entries: [
          for (final entry in json['entries'] as List<dynamic>? ?? const [])
            RepositoryEntry.fromJson((entry as Map).cast()),
        ],
        error: json['error'] as String?,
      );

  final ExtensionRepository repository;
  final List<RepositoryEntry> entries;
  final String? error;

  int get updates => entries
      .where((entry) => entry.status == RepositoryEntryStatus.update)
      .length;
}

/// What the trust prompt shows before a repository is added.
@immutable
class RepositoryPreview {
  const RepositoryPreview({
    required this.url,
    required this.name,
    required this.publicKey,
    required this.fingerprint,
    this.extensions = 0,
  });

  factory RepositoryPreview.fromJson(Map<String, dynamic> json) =>
      RepositoryPreview(
        url: json['url'] as String? ?? '',
        name: json['name'] as String? ?? '',
        publicKey: json['publicKey'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
        extensions: (json['extensions'] as num?)?.toInt() ?? 0,
      );

  final String url;
  final String name;
  final String publicKey;
  final String fingerprint;
  final int extensions;
}

/// What lyric and metadata searches send (EXTENSIONS.md §1).
@immutable
class TrackQuery {
  const TrackQuery({
    required this.title,
    this.artist = '',
    this.album,
    this.durationMs,
    this.isrc,
    this.language,
  });

  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? isrc;
  final String? language;

  Map<String, Object?> toJson() => {
    'title': title,
    'artist': artist,
    'album': ?album,
    'durationMs': ?durationMs,
    'isrc': ?isrc,
    'language': ?language,
  };
}

/// One lyrics candidate from an extension, ranked by Rust.
@immutable
class LyricsCandidate {
  const LyricsCandidate({
    required this.extensionId,
    required this.extensionName,
    required this.id,
    required this.format,
    this.title = '',
    this.artist = '',
    this.album,
    this.durationMs,
    this.body,
    this.language,
    this.score = 0,
  });

  factory LyricsCandidate.fromJson(Map<String, dynamic> json) =>
      LyricsCandidate(
        extensionId: json['extensionId'] as String? ?? '',
        extensionName:
            json['extensionName'] as String? ??
            json['extensionId'] as String? ??
            '',
        id: json['id'] as String? ?? '',
        format: json['format'] as String? ?? 'plain',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        body: json['body'] as String?,
        language: json['language'] as String?,
        score: (json['score'] as num?)?.toDouble() ?? 0,
      );

  final String extensionId;
  final String extensionName;
  final String id;

  /// `plain`, `lrc`, `elrc` or `ttml`.
  final String format;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;

  /// Null when the extension serves the text through `getLyrics`.
  final String? body;
  final String? language;
  final double score;

  bool get synced => format != 'plain';

  LyricsCandidate withBody(String body) => LyricsCandidate(
    extensionId: extensionId,
    extensionName: extensionName,
    id: id,
    format: format,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    body: body,
    language: language,
    score: score,
  );
}

/// A failed provider in a multi-extension search.
typedef ExtensionFailure = ({String extensionId, String name, String message});

List<ExtensionFailure> extensionFailures(Object? value) => [
  for (final error in value as List<dynamic>? ?? const [])
    (
      extensionId: (error as Map)['extensionId'] as String? ?? '',
      name: error['name'] as String? ?? '',
      message: error['message'] as String? ?? '',
    ),
];

/// A track from a metadata extension (EXTENSIONS.md §1 `metadata`).
@immutable
class TrackResult {
  const TrackResult({
    required this.extensionId,
    required this.id,
    required this.title,
    this.extensionName = '',
    this.artists = const [],
    this.album,
    this.durationMs,
    this.isrc,
    this.language,
    this.artworkUrl,
    this.year,
    this.alternatives = const [],
  });

  factory TrackResult.fromJson(Map<String, dynamic> json) => TrackResult(
    extensionId: json['extensionId'] as String? ?? '',
    extensionName: json['extensionName'] as String? ?? '',
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    artists: _strings(json['artists']),
    album: json['album'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt(),
    isrc: json['isrc'] as String?,
    language: json['language'] as String?,
    artworkUrl: json['artworkUrl'] as String?,
    year: (json['year'] as num?)?.toInt(),
    alternatives: [
      for (final alt in json['alternatives'] as List<dynamic>? ?? const [])
        (
          extensionId: (alt as Map)['extensionId'] as String? ?? '',
          id: alt['id'] as String? ?? '',
        ),
    ],
  );

  final String extensionId;
  final String extensionName;
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final String? isrc;
  final String? language;
  final String? artworkUrl;
  final int? year;

  /// The same song from other extensions.
  final List<({String extensionId, String id})> alternatives;

  String get artist => artists.join(', ');

  /// What `resolveAudio` and `getArtwork` receive.
  Map<String, Object?> toJson() => {
    'extensionId': extensionId,
    'id': id,
    'title': title,
    'artists': artists,
    'artist': artist,
    'album': ?album,
    'durationMs': ?durationMs,
    'isrc': ?isrc,
    'language': ?language,
    'artworkUrl': ?artworkUrl,
  };
}

/// `song.ext_ref`: where an extension song came from, so it can be streamed
/// and downloaded later (DATA_MODEL.md §2).
@immutable
class ExtensionTrackRef {
  const ExtensionTrackRef({
    required this.extensionId,
    required this.trackId,
    this.track = const {},
  });

  factory ExtensionTrackRef.fromJson(Map<String, dynamic> json) =>
      ExtensionTrackRef(
        extensionId: json['extensionId'] as String? ?? '',
        trackId: json['trackId'] as String? ?? '',
        track: _map(json['track']),
      );

  factory ExtensionTrackRef.of(TrackResult track) => ExtensionTrackRef(
    extensionId: track.extensionId,
    trackId: track.id,
    track: track.toJson(),
  );

  final String extensionId;
  final String trackId;

  /// The track as the metadata extension returned it.
  final Map<String, Object?> track;

  Map<String, Object?> toJson() => {
    'extensionId': extensionId,
    'trackId': trackId,
    'track': track,
  };
}

/// A streamable source from `resolveAudio`.
@immutable
class AudioSourceRef {
  const AudioSourceRef({
    required this.kind,
    required this.url,
    this.headers = const {},
    this.format,
  });

  factory AudioSourceRef.fromJson(Map<String, dynamic> json) => AudioSourceRef(
    kind: json['kind'] as String? ?? 'original',
    url: json['url'] as String? ?? '',
    headers: {
      for (final MapEntry(:key, :value) in _map(json['headers']).entries)
        key: '$value',
    },
    format: json['format'] as String?,
  );

  /// `original`, `instrumental` or `vocals`.
  final String kind;
  final String url;
  final Map<String, String> headers;
  final String? format;
}

/// A stream for `playerLoad`: the resolved source plus the extension whose
/// network session fetches it and the cache key of its download.
@immutable
class StreamSource {
  const StreamSource({
    required this.extensionId,
    required this.source,
    required this.cacheKey,
  });

  final String extensionId;
  final AudioSourceRef source;
  final String cacheKey;

  Map<String, Object?> toJson() => {
    'kind': source.kind,
    'url': source.url,
    'headers': source.headers,
    'format': ?source.format,
    'extensionId': extensionId,
    'cacheKey': cacheKey,
  };
}

@immutable
class ExtensionLogEntry {
  const ExtensionLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  factory ExtensionLogEntry.fromJson(Map<String, dynamic> json) =>
      ExtensionLogEntry(
        timestamp: json['timestamp'] as String? ?? '',
        level: json['level'] as String? ?? 'info',
        message: json['message'] as String? ?? '',
      );

  final String timestamp;
  final String level;
  final String message;
}
