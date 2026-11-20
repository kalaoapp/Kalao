import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// One row of the `backup_run` log (DATA_MODEL.md §2).
@immutable
class BackupRun {
  const BackupRun({
    required this.startedAt,
    required this.target,
    required this.status,
    this.finishedAt,
    this.bytes = 0,
    this.error,
  });

  final DateTime startedAt;
  final DateTime? finishedAt;

  /// `folder` (scheduled) or `file` (saved by hand).
  final String target;

  /// `running`, `ok` or `failed`.
  final String status;
  final int bytes;
  final String? error;
}

/// The `backup_run` table in `kalao_library.db`.
class BackupRuns {
  BackupRuns(this.db);

  final Database db;

  Future<int> start(String target, {DateTime? now}) => db.insert('backup_run', {
    'started_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
    'target': target,
    'status': 'running',
  });

  Future<void> finish(int id, {int bytes = 0, String? error, DateTime? now}) =>
      db.update(
        'backup_run',
        {
          'finished_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
          'status': error == null ? 'ok' : 'failed',
          'bytes': bytes,
          'error': error,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Runs the process did not live to finish.
  Future<void> markInterrupted() => db.update('backup_run', {
    'status': 'failed',
    'error': 'interrupted',
  }, where: "status = 'running'");

  /// The newest run for [target], or of any target.
  Future<BackupRun?> latest({String? target, String? status}) async {
    final rows = await db.query(
      'backup_run',
      where: [
        if (target != null) 'target = ?',
        if (status != null) 'status = ?',
      ].join(' AND ').ifEmpty,
      whereArgs: [?target, ?status],
      orderBy: 'started_at DESC, id DESC',
      limit: 1,
    );
    final row = rows.firstOrNull;
    if (row == null) return null;
    DateTime? at(Object? ms) =>
        ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    return BackupRun(
      startedAt: at(row['started_at'])!,
      finishedAt: at(row['finished_at']),
      target: row['target'] as String? ?? '',
      status: row['status'] as String? ?? '',
      bytes: row['bytes'] as int? ?? 0,
      error: row['error'] as String?,
    );
  }
}

extension on String {
  String? get ifEmpty => isEmpty ? null : this;
}
