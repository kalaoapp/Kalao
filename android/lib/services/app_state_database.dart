import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/library_schema.dart';
import 'package:sqflite/sqflite.dart';

/// `kalao_app_state.db`: playback session restore and recent access.
class AppStateDatabase {
  AppStateDatabase(this.db);

  final Database db;

  static Future<AppStateDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async => AppStateDatabase(
    await openVersionedDatabase(
      path,
      version: appStateVersion,
      migrations: appStateMigrations,
      factory: factory,
    ),
  );

  Future<void> close() => db.close();

  Future<Map<String, String>> session() async => {
    for (final row in await db.query('playback_session'))
      row['key'] as String: row['value'] as String? ?? '',
  };

  Future<void> saveSession(Map<String, String> values) =>
      db.transaction((txn) async {
        await txn.delete('playback_session');
        for (final MapEntry(:key, :value) in values.entries) {
          await txn.insert('playback_session', {'key': key, 'value': value});
        }
      });

  Future<void> clearSession() => db.delete('playback_session');
}
