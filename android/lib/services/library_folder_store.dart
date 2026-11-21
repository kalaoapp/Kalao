import 'package:kalao/models/library_folder.dart';
import 'package:sqflite/sqflite.dart';

/// `folder_file.role`: what a music-folder file is to the library. A file
/// whose song was deleted keeps its row with no song, so scans leave it out.
enum FolderFileRole { original, instrumental, lyrics, skipped }

/// A file a scan has seen (`folder_file`): its size and modification time
/// tell the next scan whether it changed.
class FolderFile {
  const FolderFile({
    required this.uri,
    required this.folderId,
    this.dir = '',
    required this.name,
    required this.role,
    this.songId,
    this.bytes = 0,
    this.modified = 0,
    this.error,
  });

  factory FolderFile.fromRow(Map<String, Object?> row) => FolderFile(
    uri: row['uri']! as String,
    folderId: row['folder_id']! as int,
    dir: row['dir'] as String? ?? '',
    name: row['name']! as String,
    role:
        FolderFileRole.values.asNameMap()[row['role']] ??
        FolderFileRole.skipped,
    songId: row['song_id'] as int?,
    bytes: row['bytes'] as int? ?? 0,
    modified: row['modified'] as int? ?? 0,
    error: row['error'] as String?,
  );

  final String uri;
  final int folderId;
  final String dir;
  final String name;
  final FolderFileRole role;
  final int? songId;
  final int bytes;
  final int modified;

  /// Why a [FolderFileRole.skipped] file was not added.
  final String? error;

  Map<String, Object?> toRow() => {
    'uri': uri,
    'folder_id': folderId,
    'dir': dir,
    'name': name,
    'role': role.name,
    'song_id': songId,
    'bytes': bytes,
    'modified': modified,
    'error': error,
  };
}

/// SQL for `library_folder` and `folder_file` in `kalao_library.db`.
class LibraryFolderStore {
  LibraryFolderStore(this.db);

  final Database db;

  static const _folderQuery = '''
SELECT f.*,
  (SELECT COUNT(*) FROM folder_file x WHERE x.folder_id = f.id
     AND x.role = 'original' AND x.song_id IS NOT NULL) AS songs,
  (SELECT COUNT(*) FROM folder_file x WHERE x.folder_id = f.id
     AND x.role = 'skipped') AS skipped
FROM library_folder f''';

  static LibraryFolder _folder(Map<String, Object?> row) => LibraryFolder(
    id: row['id']! as int,
    treeUri: row['tree_uri']! as String,
    name: row['name']! as String,
    addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at']! as int),
    scannedAt: switch (row['scanned_at']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
    error: row['error'] as String?,
    songs: row['songs'] as int? ?? 0,
    skipped: row['skipped'] as int? ?? 0,
  );

  Future<List<LibraryFolder>> folders() async => [
    for (final row in await db.rawQuery(
      '$_folderQuery ORDER BY f.name COLLATE NOCASE, f.id',
    ))
      _folder(row),
  ];

  Future<LibraryFolder?> folder(int id) async {
    final rows = await db.rawQuery('$_folderQuery WHERE f.id = ?', [id]);
    return rows.isEmpty ? null : _folder(rows.first);
  }

  /// Adds the folder, or returns the id it already has.
  Future<int> addFolder(String treeUri, String name, {DateTime? now}) async {
    final existing = await db.query(
      'library_folder',
      columns: ['id'],
      where: 'tree_uri = ?',
      whereArgs: [treeUri],
    );
    if (existing.isNotEmpty) return existing.first['id']! as int;
    return db.insert('library_folder', {
      'tree_uri': treeUri,
      'name': name,
      'added_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    });
  }

  Future<void> removeFolder(int id) =>
      db.delete('library_folder', where: 'id = ?', whereArgs: [id]);

  /// After a scan: [at] when it read the folder, [error] when it could not
  /// ([at] null keeps the last successful scan time).
  Future<void> setScanned(int id, {DateTime? at, String? error}) => db.update(
    'library_folder',
    {'scanned_at': ?at?.millisecondsSinceEpoch, 'error': error},
    where: 'id = ?',
    whereArgs: [id],
  );

  /// The files the scans have seen in folder [folderId], by URI.
  Future<Map<String, FolderFile>> files(int folderId) async => {
    for (final row in await db.query(
      'folder_file',
      where: 'folder_id = ?',
      whereArgs: [folderId],
    ))
      row['uri']! as String: FolderFile.fromRow(row),
  };

  Future<void> putFile(FolderFile file) => db.insert(
    'folder_file',
    file.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> deleteFiles(Iterable<String> uris) async {
    final list = uris.toList();
    if (list.isEmpty) return;
    await db.delete(
      'folder_file',
      where: 'uri IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
  }

  /// Forgets every file of [songIds], so a scan pairs them afresh.
  Future<void> deleteFilesOfSongs(Iterable<int> songIds) async {
    final list = songIds.toList();
    if (list.isEmpty) return;
    await db.delete(
      'folder_file',
      where: 'song_id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
  }

  /// Songs whose original is in folder [folderId].
  Future<List<int>> songIds(int folderId) async => [
    for (final row in await db.query(
      'folder_file',
      columns: ['song_id'],
      where: "folder_id = ? AND role = 'original' AND song_id IS NOT NULL",
      whereArgs: [folderId],
    ))
      row['song_id']! as int,
  ];

  Future<List<SkippedFolderFile>> skipped(int folderId) async => [
    for (final row in await db.query(
      'folder_file',
      where: "folder_id = ? AND role = 'skipped'",
      whereArgs: [folderId],
      orderBy: 'dir, name',
    ))
      (
        dir: row['dir'] as String? ?? '',
        name: row['name']! as String,
        reason: row['error'] as String? ?? '',
      ),
  ];
}
