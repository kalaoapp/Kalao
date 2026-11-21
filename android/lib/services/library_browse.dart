// Library browsing follows Mornye's library_browse_provider.dart,
// library_counts_provider.dart, library_genres_provider.dart and
// library_directory_index.dart (bounded SQLite reads, shared counts, genre
// splitting, a folder index), adapted to Kalao's `song` table and karaoke
// filters (MORNYE_REUSE.md §7).
import 'package:flutter/foundation.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/models/song.dart';

/// How the Library lists songs (FEATURES 6.11).
enum LibrarySort { latest, oldest, title, artist, album, year, genre, size }

/// Where a song came from: imported into app storage, a music folder, or an
/// extension.
enum SongOrigin { imported, folder, extension }

/// What a song's current lyrics are timed to.
enum LyricsFilter { none, plain, lines, words }

/// One filtered, sorted view of the songs. Equal queries share their count
/// and pages.
@immutable
class SongQuery {
  const SongQuery({
    this.sort = LibrarySort.latest,
    this.favoritesOnly = false,
    this.origin,
    this.codec,
    this.lyrics,
    this.hasInstrumental,
    this.unavailableOnly = false,
    this.missingArtwork = false,
    this.missingGenre = false,
    this.missingYear = false,
    this.album,
    this.artist,
    this.genre,
    this.folder,
  });

  final LibrarySort sort;
  final bool favoritesOnly;
  final SongOrigin? origin;

  /// The original's codec (`flac`, `mp3`…).
  final String? codec;
  final LyricsFilter? lyrics;
  final bool? hasInstrumental;
  final bool unavailableOnly;
  final bool missingArtwork;
  final bool missingGenre;
  final bool missingYear;

  /// Scopes for the album, artist, genre and folder pages.
  final AlbumRef? album;
  final String? artist;

  /// A [GenreSummary.key].
  final String? genre;
  final FolderRef? folder;

  /// Filters the user set (not the page scope or the sort).
  int get activeFilters => [
    favoritesOnly,
    origin != null,
    codec != null,
    lyrics != null,
    hasInstrumental != null,
    unavailableOnly,
    missingArtwork,
    missingGenre,
    missingYear,
  ].where((on) => on).length;

  SongQuery copyWith({
    LibrarySort? sort,
    bool? favoritesOnly,
    ValueGetter<SongOrigin?>? origin,
    ValueGetter<String?>? codec,
    ValueGetter<LyricsFilter?>? lyrics,
    ValueGetter<bool?>? hasInstrumental,
    bool? unavailableOnly,
    bool? missingArtwork,
    bool? missingGenre,
    bool? missingYear,
  }) => SongQuery(
    sort: sort ?? this.sort,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    origin: origin == null ? this.origin : origin(),
    codec: codec == null ? this.codec : codec(),
    lyrics: lyrics == null ? this.lyrics : lyrics(),
    hasInstrumental: hasInstrumental == null
        ? this.hasInstrumental
        : hasInstrumental(),
    unavailableOnly: unavailableOnly ?? this.unavailableOnly,
    missingArtwork: missingArtwork ?? this.missingArtwork,
    missingGenre: missingGenre ?? this.missingGenre,
    missingYear: missingYear ?? this.missingYear,
    album: album,
    artist: artist,
    genre: genre,
    folder: folder,
  );

  /// The filters cleared, the scope and sort kept.
  SongQuery cleared() => SongQuery(
    sort: sort,
    album: album,
    artist: artist,
    genre: genre,
    folder: folder,
  );

  SongQuery scoped({
    AlbumRef? album,
    String? artist,
    String? genre,
    FolderRef? folder,
  }) => SongQuery(
    sort: sort,
    album: album,
    artist: artist,
    genre: genre,
    folder: folder,
  );

  @override
  bool operator ==(Object other) =>
      other is SongQuery &&
      other.sort == sort &&
      other.favoritesOnly == favoritesOnly &&
      other.origin == origin &&
      other.codec == codec &&
      other.lyrics == lyrics &&
      other.hasInstrumental == hasInstrumental &&
      other.unavailableOnly == unavailableOnly &&
      other.missingArtwork == missingArtwork &&
      other.missingGenre == missingGenre &&
      other.missingYear == missingYear &&
      other.album == album &&
      other.artist == artist &&
      other.genre == genre &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(
    sort,
    favoritesOnly,
    origin,
    codec,
    lyrics,
    hasInstrumental,
    unavailableOnly,
    missingArtwork,
    missingGenre,
    missingYear,
    album,
    artist,
    genre,
    folder,
  );
}

/// An album: its name and its artist (album artist, else artist), compared
/// without case.
@immutable
class AlbumRef {
  const AlbumRef(this.name, this.artist);

  final String name;
  final String artist;

  @override
  bool operator ==(Object other) =>
      other is AlbumRef &&
      other.name.toLowerCase() == name.toLowerCase() &&
      other.artist.toLowerCase() == artist.toLowerCase();

  @override
  int get hashCode => Object.hash(name.toLowerCase(), artist.toLowerCase());

  /// `album_artwork.album_key`.
  String get key => '${name.toLowerCase()}|${artist.toLowerCase()}';
}

/// A directory in a music folder; [dir] is the path below it ('' = top).
@immutable
class FolderRef {
  const FolderRef(this.folderId, this.dir);

  final int folderId;
  final String dir;

  @override
  bool operator ==(Object other) =>
      other is FolderRef && other.folderId == folderId && other.dir == dir;

  @override
  int get hashCode => Object.hash(folderId, dir);
}

typedef AlbumSummary = ({
  AlbumRef ref,
  int songs,
  String? coverPath,
  int? year,
});

typedef ArtistSummary = ({String name, int songs, String? coverPath});

/// A genre: [key] is lower case without spaces, [name] its most common
/// spelling.
typedef GenreSummary = ({String key, String name, int songs});

/// One level of a music folder: the directories right below it, with how
/// many songs are under each, and how many songs sit in it directly.
typedef FolderLevel = ({
  List<({String name, String dir, int songs})> dirs,
  int songs,
});

/// The SQL behind the Library pages (FEATURES 6.11).
class LibraryBrowse {
  LibraryBrowse(this.library);

  final LibraryDatabase library;

  /// Genre tags are split on these, as Mornye's `tags/separators.rs`.
  static final genreSeparators = RegExp(r'[;/,；、|]');

  static String genreKey(String genre) =>
      genre.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  /// The genres one tag lists.
  static List<String> splitGenres(String? tag) => [
    for (final part in (tag ?? '').split(genreSeparators))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  /// The original's media row, for codec, origin and size.
  static const _original =
      "(SELECT m.{column} FROM media_file m WHERE m.song_id = song.id AND m.kind = 'original')";

  static String _originalColumn(String column) =>
      _original.replaceFirst('{column}', column);

  static const _currentLyrics = '''
(SELECT d.json FROM lyric_doc d WHERE d.song_id = song.id
  ORDER BY d.version DESC LIMIT 1)''';

  /// SQL normalising `song.genre` to `;key;key;` for [genreKey] matching.
  static const _genreKeys =
      "(';' || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LOWER(COALESCE(song.genre, '')), ' ', ''), '/', ';'), ',', ';'), '；', ';'), '、', ';'), '|', ';'), char(9), ''), char(10), '') || ';')";

  (String, List<Object?>) _where(SongQuery query) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (query.favoritesOnly) {
      clauses.add('song.id IN (SELECT song_id FROM favorite)');
    }
    switch (query.origin) {
      case SongOrigin.extension:
        clauses.add("song.origin = 'extension'");
      case SongOrigin.folder:
        clauses.add("${_originalColumn('source')} = 'folder'");
      case SongOrigin.imported:
        clauses.add(
          "song.origin != 'extension' AND ${_originalColumn('source')} = 'import'",
        );
      case null:
        break;
    }
    if (query.codec case final codec?) {
      clauses.add('LOWER(${_originalColumn('codec')}) = ?');
      args.add(codec.toLowerCase());
    }
    switch (query.lyrics) {
      case LyricsFilter.none:
        clauses.add(
          'NOT EXISTS (SELECT 1 FROM lyric_doc d WHERE d.song_id = song.id)',
        );
      case LyricsFilter.plain:
        clauses.add("$_currentLyrics NOT LIKE '%\"timed\":true%'");
      case LyricsFilter.lines:
        clauses.add(
          "$_currentLyrics LIKE '%\"timed\":true%' AND $_currentLyrics NOT LIKE '%\"words\":[{%'",
        );
      case LyricsFilter.words:
        clauses.add("$_currentLyrics LIKE '%\"words\":[{%'");
      case null:
        break;
    }
    if (query.hasInstrumental case final has?) {
      clauses.add(
        "${has ? '' : 'NOT '}EXISTS (SELECT 1 FROM media_file m WHERE m.song_id = song.id AND m.kind = 'instrumental')",
      );
    }
    if (query.unavailableOnly) {
      clauses.add('${_originalColumn('available')} = 0');
    }
    if (query.missingArtwork) clauses.add('song.cover_path IS NULL');
    if (query.missingGenre) {
      clauses.add("(song.genre IS NULL OR TRIM(song.genre) = '')");
    }
    if (query.missingYear) clauses.add('song.year IS NULL');
    if (query.album case final album?) {
      clauses.add(
        "LOWER(song.album) = ? AND LOWER(COALESCE(NULLIF(TRIM(song.album_artist), ''), song.artist)) = ?",
      );
      args
        ..add(album.name.toLowerCase())
        ..add(album.artist.toLowerCase());
    }
    if (query.artist case final artist?) {
      clauses.add(
        "(LOWER(song.artist) = ? OR LOWER(COALESCE(song.album_artist, '')) = ?)",
      );
      args
        ..add(artist.toLowerCase())
        ..add(artist.toLowerCase());
    }
    if (query.genre case final genre?) {
      clauses.add("$_genreKeys LIKE ?");
      args.add('%;$genre;%');
    }
    if (query.folder case final folder?) {
      clauses.add(
        "song.id IN (SELECT song_id FROM folder_file WHERE folder_id = ? AND role = 'original' AND song_id IS NOT NULL AND (? = '' OR dir = ? OR dir LIKE ? || '/%'))",
      );
      args.addAll([folder.folderId, folder.dir, folder.dir, folder.dir]);
    }
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', args);
  }

  static String _order(SongQuery query) {
    if (query.album != null) {
      return 'COALESCE(song.disc_no, 1), COALESCE(song.track_no, 9999), song.title COLLATE NOCASE, song.id';
    }
    return switch (query.sort) {
      LibrarySort.latest => 'song.added_at DESC, song.id DESC',
      LibrarySort.oldest => 'song.added_at, song.id',
      LibrarySort.title => 'song.title COLLATE NOCASE, song.id',
      LibrarySort.artist =>
        'song.artist COLLATE NOCASE, song.title COLLATE NOCASE, song.id',
      LibrarySort.album =>
        "song.album = '', song.album COLLATE NOCASE, COALESCE(song.disc_no, 1), COALESCE(song.track_no, 9999), song.id",
      LibrarySort.year =>
        'song.year IS NULL, song.year DESC, song.title COLLATE NOCASE, song.id',
      LibrarySort.genre =>
        "COALESCE(song.genre, '') = '', song.genre COLLATE NOCASE, song.title COLLATE NOCASE, song.id",
      LibrarySort.size =>
        "COALESCE(${_originalColumn('bytes')}, 0) DESC, song.id",
    };
  }

  /// One page of [query]'s songs.
  Future<List<Song>> page(
    SongQuery query, {
    int offset = 0,
    int limit = 100,
  }) async {
    final (where, args) = _where(query);
    final rows = await library.db.rawQuery(
      'SELECT song.* FROM song $where ORDER BY ${_order(query)} LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return library.songsFromRows(rows);
  }

  /// Every song id of [query], in its order (Sing all, Shuffle).
  Future<List<int>> ids(SongQuery query) async {
    final (where, args) = _where(query);
    return [
      for (final row in await library.db.rawQuery(
        'SELECT song.id FROM song $where ORDER BY ${_order(query)}',
        args,
      ))
        row['id']! as int,
    ];
  }

  Future<int> count(SongQuery query) async {
    final (where, args) = _where(query);
    final rows = await library.db.rawQuery(
      'SELECT COUNT(*) AS n FROM song $where',
      args,
    );
    return rows.first['n']! as int;
  }

  /// The codecs of the library's originals, for the Format filter.
  Future<List<String>> codecs() async => [
    for (final row in await library.db.rawQuery(
      "SELECT DISTINCT LOWER(codec) AS codec FROM media_file WHERE kind = 'original' AND codec != '' ORDER BY 1",
    ))
      row['codec']! as String,
  ];

  /// Albums with a name, by name.
  Future<List<AlbumSummary>> albums({String? artist}) async {
    final rows = await library.db.rawQuery(
      '''
SELECT MIN(song.album) AS name,
  MIN(COALESCE(NULLIF(TRIM(song.album_artist), ''), song.artist)) AS artist,
  COUNT(*) AS songs, MAX(song.cover_path) AS cover, MAX(song.year) AS year
FROM song
WHERE TRIM(song.album) != ''${artist == null ? '' : " AND (LOWER(song.artist) = ? OR LOWER(COALESCE(song.album_artist, '')) = ?)"}
GROUP BY LOWER(song.album), LOWER(COALESCE(NULLIF(TRIM(song.album_artist), ''), song.artist))
ORDER BY name COLLATE NOCASE''',
      [?artist?.toLowerCase(), ?artist?.toLowerCase()],
    );
    return [
      for (final row in rows)
        (
          ref: AlbumRef(row['name']! as String, row['artist'] as String? ?? ''),
          songs: row['songs']! as int,
          coverPath: row['cover'] as String?,
          year: row['year'] as int?,
        ),
    ];
  }

  /// Artists by name (the song's artist tag).
  Future<List<ArtistSummary>> artists() async {
    final rows = await library.db.rawQuery('''
SELECT MIN(artist) AS name, COUNT(*) AS songs, MAX(cover_path) AS cover
FROM song WHERE TRIM(artist) != ''
GROUP BY LOWER(artist) ORDER BY name COLLATE NOCASE''');
    return [
      for (final row in rows)
        (
          name: row['name']! as String,
          songs: row['songs']! as int,
          coverPath: row['cover'] as String?,
        ),
    ];
  }

  /// Genres; a tag that lists several counts its song under each.
  Future<List<GenreSummary>> genres() async {
    final counts = <String, int>{};
    final spellings = <String, Map<String, int>>{};
    for (final row in await library.db.rawQuery(
      "SELECT genre FROM song WHERE genre IS NOT NULL AND TRIM(genre) != ''",
    )) {
      for (final genre in splitGenres(row['genre'] as String?).toSet()) {
        final key = genreKey(genre);
        counts[key] = (counts[key] ?? 0) + 1;
        final names = spellings[key] ??= {};
        names[genre] = (names[genre] ?? 0) + 1;
      }
    }
    final genres = [
      for (final MapEntry(:key, value: songs) in counts.entries)
        (
          key: key,
          name:
              (spellings[key]!.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                  .first
                  .key,
          songs: songs,
        ),
    ];
    genres.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return genres;
  }

  /// The level [dir] of music folder [folderId].
  Future<FolderLevel> folderLevel(int folderId, String dir) async {
    final rows = await library.db.rawQuery(
      '''
SELECT dir, COUNT(*) AS songs FROM folder_file
WHERE folder_id = ? AND role = 'original' AND song_id IS NOT NULL
  AND (? = '' OR dir = ? OR dir LIKE ? || '/%')
GROUP BY dir''',
      [folderId, dir, dir, dir],
    );
    final below = <String, int>{};
    var here = 0;
    for (final row in rows) {
      final path = row['dir']! as String;
      final songs = row['songs']! as int;
      if (path == dir) {
        here += songs;
        continue;
      }
      final rest = dir.isEmpty ? path : path.substring(dir.length + 1);
      final name = rest.split('/').first;
      below[name] = (below[name] ?? 0) + songs;
    }
    final names = below.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return (
      dirs: [
        for (final name in names)
          (
            name: name,
            dir: dir.isEmpty ? name : '$dir/$name',
            songs: below[name]!,
          ),
      ],
      songs: here,
    );
  }

  /// The songs directly in [folder] (not below it).
  Future<List<Song>> folderSongs(FolderRef folder) async {
    final rows = await library.db.rawQuery(
      '''
SELECT song.* FROM song JOIN folder_file f ON f.song_id = song.id
WHERE f.folder_id = ? AND f.role = 'original' AND f.dir = ?
ORDER BY COALESCE(song.disc_no, 1), COALESCE(song.track_no, 9999), f.name COLLATE NOCASE''',
      [folder.folderId, folder.dir],
    );
    return library.songsFromRows(rows);
  }

  /// Whether the library has a song with this ISRC or song key ("In
  /// Library" on extension results, FEATURES 6.12).
  Future<Set<String>> knownKeys(Iterable<String> keys) async {
    final list = keys.toSet().toList();
    if (list.isEmpty) return const {};
    final rows = await inChunks(
      list,
      (chunk, marks) => library.db.rawQuery(
        'SELECT DISTINCT song_key FROM song WHERE song_key IN ($marks)',
        chunk,
      ),
    );
    return {for (final row in rows) row['song_key']! as String};
  }
}
