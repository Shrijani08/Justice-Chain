import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/ai_service.dart';
import 'package:justice_chain/core/disguise_service.dart';
import 'package:justice_chain/core/emergency_controller.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/protection_service.dart';

/// Step 6b phase 3: the dead-stream watchdog and "Keep listening while disguised".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const protection = MethodChannel('in.sakshya/protection');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('AIService.streamLooksDead', () {
    bool dead({int silentSeconds = 0, int zeroWindows = 0, int? sinceRestartSeconds}) =>
        AIService.streamLooksDead(
          sinceLastAudio: Duration(seconds: silentSeconds),
          zeroWindowsInARow: zeroWindows,
          sinceLastRestart: sinceRestartSeconds == null ? null : Duration(seconds: sinceRestartSeconds),
        );

    test('a stream that delivers ordinary audio is alive', () {
      expect(dead(silentSeconds: 1, zeroWindows: 3), isFalse);
    });

    test('5 s without any audio means dead (e.g. paused by another app)', () {
      expect(dead(silentSeconds: 5), isTrue);
    });

    test('15 windows of exact digital silence mean dead (e.g. a call took the microphone)', () {
      expect(dead(zeroWindows: 14), isFalse);
      expect(dead(zeroWindows: 15), isTrue);
    });

    test('restarts are at least 30 s apart, so a long call does not loop them', () {
      expect(dead(silentSeconds: 60, sinceRestartSeconds: 10), isFalse);
      expect(dead(silentSeconds: 60, sinceRestartSeconds: 30), isTrue);
    });
  });

  group('Keep listening while disguised', () {
    late Directory tempDir;
    late List<MethodCall> calls;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('listening_rule_test');
      Hive.init(tempDir.path);
      await Hive.openBox('vault_box');
      FlutterSecureStorage.setMockInitialValues({});
      await IdentityService.initializeDevice();
      messenger.setMockMethodCallHandler(const MethodChannel('in.sakshya/disguise'), (call) async => 'sakshya');
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'), (call) async => null);
      await ProtectionService.init();
    });

    setUp(() async {
      calls = [];
      messenger.setMockMethodCallHandler(protection, (call) async {
        calls.add(call);
        return true;
      });
      ProtectionService.enabled.value = true;
      await ProtectionService.setListenWhileDisguised(true);
      DisguiseService.enabled.value = false;
      await EmergencyController.startBackgroundMonitoring();
      calls.clear();
    });

    tearDown(() async {
      await EmergencyController.shutdownMonitoring();
      messenger.setMockMethodCallHandler(protection, null);
    });

    tearDownAll(() async {
      await Hive.deleteFromDisk();
      await Hive.close();
    });

    test('is on by default and saved', () async {
      expect(ProtectionService.listenWhileDisguised.value, isTrue);
      await ProtectionService.setListenWhileDisguised(false);
      expect(Hive.box('vault_box').get('listen_while_disguised'), isFalse);
    });

    test('on: disguise keeps the service running', () async {
      expect(EmergencyController.listeningAllowed, isTrue);
      DisguiseService.enabled.value = true;
      await pumpEventQueue();
      expect(EmergencyController.listeningAllowed, isTrue);
      expect(calls.map((c) => c.method), isNot(contains('stop')));
    });

    test('off: disguise stops the service, and undisguising starts it again', () async {
      await ProtectionService.setListenWhileDisguised(false);
      await pumpEventQueue();
      expect(calls.map((c) => c.method), isNot(contains('stop'))); // not disguised yet

      DisguiseService.enabled.value = true;
      await pumpEventQueue();
      expect(EmergencyController.listeningAllowed, isFalse);
      expect(calls.map((c) => c.method), contains('stop'));

      calls.clear();
      DisguiseService.enabled.value = false;
      await pumpEventQueue();
      expect(EmergencyController.listeningAllowed, isTrue);
      expect(calls.map((c) => c.method), contains('start'));
    });

    test('turning the switch back on while disguised starts listening', () async {
      await ProtectionService.setListenWhileDisguised(false);
      DisguiseService.enabled.value = true;
      await pumpEventQueue();
      calls.clear();

      await ProtectionService.setListenWhileDisguised(true);
      await pumpEventQueue();
      expect(calls.map((c) => c.method), contains('start'));
    });
  });
}
