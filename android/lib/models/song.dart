import 'package:flutter/foundation.dart';

/// `media_file.kind`: which part of a song a file plays.
enum MediaKind { original, instrumental, vocals }

/// A song row from `kalao_library.db` (DATA_MODEL.md §2) with its files.
@immutable
class Song {
  const Song({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationMs,
    this.coverPath,
    required this.addedAt,
    this.lastMode,
    this.media = const [],
    this.hasLyrics = false,
    this.favorite = false,
    this.songKey = '',
  });

  final int id;
  final String title;
  final String artist;
  final String album;
  final int? durationMs;
  final String? coverPath;
  final DateTime addedAt;
  final String? lastMode;
  final List<MediaFile> media;
  final bool hasLyrics;

  /// In `favorite`.
  final bool favorite;

  /// `song.song_key`: matches the song across backups and devices.
  final String songKey;

  MediaFile? file(MediaKind kind) {
    for (final file in media) {
      if (file.kind == kind) return file;
    }
    return null;
  }

  /// Original + instrumental (or stems) are present: karaoke switching works.
  bool get hasBacking =>
      file(MediaKind.instrumental) != null &&
      (file(MediaKind.original) != null || file(MediaKind.vocals) != null);

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  Song copyWith({
    List<MediaFile>? media,
    bool? hasLyrics,
    String? lastMode,
    bool? favorite,
  }) => Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    coverPath: coverPath,
    addedAt: addedAt,
    lastMode: lastMode ?? this.lastMode,
    media: media ?? this.media,
    hasLyrics: hasLyrics ?? this.hasLyrics,
    favorite: favorite ?? this.favorite,
    songKey: songKey,
  );

  @override
  bool operator ==(Object other) =>
      other is Song &&
      other.id == id &&
      other.title == title &&
      other.artist == artist &&
      other.coverPath == coverPath &&
      other.hasLyrics == hasLyrics &&
      other.favorite == favorite &&
      listEquals(other.media, media);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    artist,
    coverPath,
    hasLyrics,
    favorite,
    media.length,
  );
}

@immutable
class MediaFile {
  const MediaFile({
    required this.kind,
    required this.path,
    required this.sha256,
    this.codec = '',
  });

  final MediaKind kind;
  final String path;
  final String sha256;
  final String codec;

  @override
  bool operator ==(Object other) =>
      other is MediaFile &&
      other.kind == kind &&
      other.path == path &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(kind, path, sha256);
}
