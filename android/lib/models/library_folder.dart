import 'package:flutter/foundation.dart';

/// A music folder (FEATURES 6.8): a folder the user granted with the Storage
/// Access Framework, scanned for songs that play in place
/// (`library_folder`, DATA_MODEL.md §2).
@immutable
class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.treeUri,
    required this.name,
    required this.addedAt,
    this.scannedAt,
    this.error,
    this.songs = 0,
    this.skipped = 0,
  });

  final int id;
  final String treeUri;

  /// The folder's path as the user sees it (`Music/Karaoke`).
  final String name;
  final DateTime addedAt;

  /// When the last scan finished; null before the first.
  final DateTime? scannedAt;

  /// [lostAccess] when the last scan could not read the folder.
  final String? error;

  /// Songs from this folder in the library.
  final int songs;

  /// Audio files the last scans could not add (unreadable or a format the
  /// engine cannot play in place).
  final int skipped;

  static const lostAccess = 'access';

  bool get accessLost => error == lostAccess;

  @override
  bool operator ==(Object other) =>
      other is LibraryFolder &&
      other.id == id &&
      other.treeUri == treeUri &&
      other.name == name &&
      other.addedAt == addedAt &&
      other.scannedAt == scannedAt &&
      other.error == error &&
      other.songs == songs &&
      other.skipped == skipped;

  @override
  int get hashCode =>
      Object.hash(id, treeUri, name, addedAt, scannedAt, error, songs, skipped);
}

/// An audio file a scan could not add, for the folder screen.
typedef SkippedFolderFile = ({String dir, String name, String reason});
