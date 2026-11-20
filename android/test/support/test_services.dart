import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:kalao/providers/library_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kalao/providers/player_provider.dart';
import 'package:kalao/providers/update_provider.dart';
import 'package:kalao/services/app_state_database.dart';
import 'package:kalao/services/update_service.dart';
import 'package:kalao/services/app_storage.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/import_service.dart';
import 'package:kalao/services/karaoke_deck.dart';
import 'package:kalao/services/library_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Databases in a temporary storage root, as `main` opens them.
Future<LibraryServices> openTestServices({AudioConverter? convert}) async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;
  final root = await Directory.systemTemp.createTemp('kalao-test-');
  final storage = AppStorage(root);
  await storage.ensure();
  final library = await LibraryDatabase.open(
    p.join(root.path, 'library.db'),
    factory: factory,
  );
  return LibraryServices(
    storage: storage,
    library: library,
    history: await HistoryDatabase.open(
      p.join(root.path, 'history.db'),
      factory: factory,
    ),
    appState: await AppStateDatabase.open(
      p.join(root.path, 'app_state.db'),
      factory: factory,
    ),
    importer: ImportService(
      library: library,
      storage: storage,
      convert: convert ?? (input, output) async => false,
    ),
  );
}

Future<void> closeTestServices(LibraryServices services) async {
  await services.library.close();
  await services.history.close();
  await services.appState.close();
  if (services.storage.root.existsSync()) {
    await services.storage.root.delete(recursive: true);
  }
}

/// Provider overrides for a widget test: test databases and a deck whose
/// position stream is fed by [events] instead of the platform.
List<Override> testOverrides(
  LibraryServices services, {
  Stream<Object?>? events,
}) => [
  libraryServicesProvider.overrideWithValue(services),
  // GitHub has no release yet: the startup update check finds nothing.
  updateServiceProvider.overrideWithValue(
    UpdateService(
      client: MockClient((request) async => http.Response('', 404)),
      cacheDir: Directory(p.join(services.storage.root.path, 'updates')),
    ),
  ),
  karaokeDeckProvider.overrideWith((ref) {
    final deck = KaraokeDeck(events: events ?? const Stream.empty())..start();
    ref.onDispose(deck.dispose);
    return deck;
  }),
];
