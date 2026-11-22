import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kalao/models/extension.dart';

/// A music-folder file (FEATURES 6.8) is stored by its document URI: Kalao
/// plays it in place and never copies, moves or deletes it.
bool isDocumentUri(String path) => path.startsWith('content://');

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
    this.isrc,
    this.language,
    this.extRef,
    this.albumArtist,
    this.trackNo,
    this.discNo,
    this.year,
    this.genre,
    this.composer,
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
  final String? isrc;

  /// BCP-47 language of the song, when known (from metadata or lyrics).
  final String? language;

  /// Set for songs added from an extension (`song.origin = extension`):
  /// they stream until downloaded (FEATURES 1.8, 6.6).
  final ExtensionTrackRef? extRef;

  /// Tags read from the file (FEATURES 6.10).
  final String? albumArtist;
  final int? trackNo;
  final int? discNo;
  final int? year;
  final String? genre;
  final String? composer;

  bool get fromExtension => extRef != null;

  /// The album's artist: the album-artist tag, else the song's artist.
  String get albumArtistOrArtist =>
      albumArtist?.trim().isNotEmpty ?? false ? albumArtist!.trim() : artist;

  /// Plays from a stream: an extension song with no downloaded files.
  bool get streams => media.isEmpty && extRef != null;

  /// A music-folder song whose original is gone or whose folder is offline
  /// (FEATURES 6.9): kept with its lyrics and plays, but it cannot play.
  bool get unavailable => !(file(MediaKind.original)?.available ?? true);

  bool get playable => !unavailable && (media.isNotEmpty || extRef != null);

  /// `song.ext_ref` text as stored.
  static ExtensionTrackRef? parseExtRef(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return ExtensionTrackRef.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>(),
      );
    } on FormatException {
      return null;
    }
  }

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
    isrc: isrc,
    language: language,
    extRef: extRef,
    albumArtist: albumArtist,
    trackNo: trackNo,
    discNo: discNo,
    year: year,
    genre: genre,
    composer: composer,
  );

  @override
  bool operator ==(Object other) =>
      other is Song &&
      other.id == id &&
      other.title == title &&
      other.artist == artist &&
      other.coverPath == coverPath &&
      other.album == album &&
      other.hasLyrics == hasLyrics &&
      other.favorite == favorite &&
      other.genre == genre &&
      other.year == year &&
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
    this.bytes = 0,
    this.available = true,
    this.decodable = true,
  });

  final MediaKind kind;

  /// A file in app storage, or a music-folder document URI ([inFolder]).
  final String path;

  /// Empty for music-folder files, which are not hashed.
  final String sha256;
  final String codec;
  final int bytes;

  /// False while a music-folder file is gone or its folder is offline.
  final bool available;

  /// False for a music-folder file the engine cannot decode: it plays from
  /// a FLAC copy made on first play (`converted/`).
  final bool decodable;

  bool get inFolder => isDocumentUri(path);

  @override
  bool operator ==(Object other) =>
      other is MediaFile &&
      other.kind == kind &&
      other.path == path &&
      other.sha256 == sha256 &&
      other.available == available &&
      other.decodable == decodable;

  @override
  int get hashCode => Object.hash(kind, path, sha256, available, decodable);
}
