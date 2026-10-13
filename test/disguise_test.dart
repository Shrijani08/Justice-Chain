import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/disguise_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/logic/safety_signals.dart';
import 'package:justice_chain/presentation/disguise_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('in.sakshya/disguise');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late String face; // what the fake launcher shows
  late List<String> switches;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('disguise_test');
    Hive.init(tempDir.path);
    await Hive.openBox('vault_box');
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
    face = 'sakshya';
    switches = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setLauncherFace') {
        face = (call.arguments as Map)['face'] as String;
        switches.add(face);
      }
      return face;
    });
    DisguiseService.enabled.value = false;
    sosRequested.value = false;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('DisguiseService', () {
    test('can only be turned on once a PIN is set', () async {
      await expectLater(DisguiseService.setEnabled(true), throwsStateError);
      expect(switches, isEmpty);
      expect(DisguiseService.enabled.value, isFalse);
    });

    test('switches the launcher face both ways and remembers the setting', () async {
      await IdentityService.registerNode(name: 'Asha', pin: '2580');
      await DisguiseService.setEnabled(true);
      expect(face, 'calculator');
      expect(DisguiseService.enabled.value, isTrue);
      expect(await DisguiseService.launcherFace(), LauncherFace.calculator);

      DisguiseService.enabled.value = false;
      await DisguiseService.init();
      expect(DisguiseService.enabled.value, isTrue, reason: 'read back from Hive');

      await DisguiseService.setEnabled(false);
      expect(face, 'sakshya');
      expect(switches, ['calculator', 'sakshya']);
    });

    test('start-up repairs a launcher that does not match the setting', () async {
      await Hive.box('vault_box').put('disguise_mode', true);
      await DisguiseService.init();
      expect(switches, ['calculator']);
      await DisguiseService.init();
      expect(switches, ['calculator'], reason: 'already matching: nothing switched');
    });

    test('where there is no launcher channel, nothing breaks', () async {
      messenger.setMockMethodCallHandler(channel, null);
      await IdentityService.registerNode(name: 'Asha', pin: '2580');
      await DisguiseService.setEnabled(true);
      expect(DisguiseService.enabled.value, isTrue);
      expect(await DisguiseService.launcherFace(), isNull);
    });
  });

  group('DisguiseGate', () {
    Future<void> pumpGate(WidgetTester tester) async {
      await tester.runAsync(() => IdentityService.registerNode(name: 'Asha', pin: '2580'));
      DisguiseService.enabled.value = true;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: const Scaffold(body: Text('VAULT')),
        builder: (context, child) => DisguiseGate(child: child!),
      ));
    }

    Future<void> typeKeys(WidgetTester tester, String keys) async {
      for (final k in keys.split('')) {
        await tester.tap(find.byKey(ValueKey('calc-$k')));
        await tester.pump();
      }
    }

    String display(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('calc-display'))).data!;

    /// The PIN check (Argon2id) runs for real, outside the fake clock.
    Future<void> settlePinCheck(WidgetTester tester) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    testWidgets('opens on a working calculator; only the PIN shows the app', (tester) async {
      await pumpGate(tester);
      expect(find.text('VAULT'), findsNothing);
      await typeKeys(tester, '7×6=');
      expect(display(tester), '42');
      final screenWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(tester.getTopRight(find.byKey(const ValueKey('calc-display'))).dx, greaterThan(screenWidth - 40),
          reason: 'numbers sit at the right edge, as on a calculator');

      await typeKeys(tester, '1111=');
      await settlePinCheck(tester);
      expect(find.text('VAULT'), findsNothing, reason: 'wrong PIN');
      expect(display(tester), '1111');

      await typeKeys(tester, '2580=');
      await settlePinCheck(tester);
      expect(find.text('VAULT'), findsOneWidget);
      expect(find.byKey(const ValueKey('calc-display')), findsNothing);
    });

    testWidgets('locks again when the app goes to the background', (tester) async {
      await pumpGate(tester);
      await typeKeys(tester, '2580=');
      await settlePinCheck(tester);
      expect(find.text('VAULT'), findsOneWidget);

      // Away and back: no frames are drawn while paused, so look on return.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(find.text('VAULT'), findsNothing);
      expect(display(tester), '0');
    });

    testWidgets('"112 =" asks for an SOS recording without unlocking', (tester) async {
      await pumpGate(tester);
      await typeKeys(tester, '112=');
      expect(sosRequested.value, isTrue);
      expect(display(tester), '112');
      expect(find.text('VAULT'), findsNothing);
    });
  });
}
