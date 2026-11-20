import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/services/platform_bridge.dart';

import 'support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final backend = FakeBackend();

  setUp(backend.install);
  tearDown(backend.uninstall);

  test('decodes backend info from JSON text', () async {
    final info = await PlatformBridge.getBackendInfo();
    expect(info.name, 'kalao-mobile');
    expect(info.initialized, isTrue);
    expect(info.methods, ['getBackendInfo']);
  });

  test('pages native logs', () async {
    final page = await PlatformBridge.getLogs(sinceIndex: 0);
    expect(page.nextIndex, 1);
    expect(page.entries.single.message, 'initialized');
    expect(FakeBackend.argsOf(backend.calls.last), {'sinceIndex': 0});
  });

  test('unknown methods surface as PlatformException', () async {
    await expectLater(
      PlatformBridge.runNativeDataJob({'operation': 'x'}, requestId: 'job-1'),
      throwsA(isA<PlatformException>()),
    );
    final call = backend.calls.last;
    expect(call.method, 'runNativeDataJob');
    expect((call.arguments as Map<Object?, Object?>)['request_id'], 'job-1');
  });

  test('reads and deletes a __json_file spill', () async {
    final dir = await Directory.systemTemp.createTemp('kalao-spill');
    final file = File('${dir.path}/bridge_json_1.json')
      ..writeAsStringSync('{"value": 42}');
    final decoded = await PlatformBridge.decodeJsonResult({
      '__json_file': file.path,
    });
    expect(decoded, {'value': 42});
    expect(file.existsSync(), isFalse);
    await dir.delete(recursive: true);
  });

  test('decodes empty and null replies as null', () async {
    expect(await PlatformBridge.decodeJsonResult(''), isNull);
    expect(await PlatformBridge.decodeJsonResult('null'), isNull);
    expect(await PlatformBridge.decodeJsonResult(null), isNull);
  });
}
