import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kalao/constants/app_info.dart';
import 'package:kalao/app.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/test_services.dart';

late LibraryServices _services;

Future<void> pumpApp(WidgetTester tester, Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final preferences = await SharedPreferences.getInstance();
  _services = (await tester.runAsync(openTestServices))!;
  addTearDown(() => tester.runAsync(() => closeTestServices(_services)));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        ...testOverrides(_services),
      ],
      child: const KalaoApp(),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend()..install());
  tearDown(() => backend.uninstall());

  testWidgets('first run shows setup, then the shell', (tester) async {
    await pumpApp(tester, {});
    expect(find.text('Welcome to Kalao'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    // A new install sees the tutorial once, and no What's New page.
    expect(find.text('Bring your own songs'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Lyrics you can read'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to sing yet'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('settings tab shows engine info and opens logs', (tester) async {
    await pumpApp(tester, {
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': AppInfo.version,
      }),
    });
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.textContaining('kalao-mobile 0.1.0'),
      200,
      scrollable: list,
    );
    expect(find.textContaining('kalao-mobile 0.1.0'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('View logs'),
      -200,
      scrollable: list,
    );
    await tester.tap(find.text('View logs'));
    await tester.pumpAndSettle();
    expect(find.textContaining('initialized'), findsOneWidget);
  });

  testWidgets('a stored crash report shows the banner once', (tester) async {
    backend.crashReport = jsonEncode({'time': 0, 'error': 'boom'});
    await pumpApp(tester, {
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': AppInfo.version,
      }),
    });
    expect(find.byType(MaterialBanner), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsNothing);
    expect(
      backend.calls.map((c) => c.method),
      contains('clearLastCrashReport'),
    );
  });

  testWidgets('the chosen language is applied', (tester) async {
    await pumpApp(tester, {
      'app_settings': jsonEncode({
        'setupCompleted': true,
        'tutorialSeen': true,
        'whatsNewVersion': AppInfo.version,
        'localeTag': 'ja',
      }),
    });
    expect(find.text('ホーム'), findsWidgets);
  });
}
