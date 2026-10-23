import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/disguise_service.dart';
import 'package:justice_chain/core/protection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('in.sakshya/protection');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late List<MethodCall> calls; // what the fake service was asked

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('protection_test');
    Hive.init(tempDir.path);
    await Hive.openBox('vault_box');
    await ProtectionService.init(); // listens to disguise mode once
  });

  setUp(() async {
    await Hive.box('vault_box').clear();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    DisguiseService.enabled.value = false;
    ProtectionService.enabled.value = true;
    calls.clear();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
  });

  test('is on by default and starts with the normal notification', () async {
    await ProtectionService.init();
    expect(ProtectionService.enabled.value, isTrue);

    expect(await ProtectionService.startIfEnabled(), isTrue);
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, {'disguised': false});
  });

  test('turning it off stops the service, is saved, and blocks later starts', () async {
    await ProtectionService.setEnabled(false);
    expect(calls.single.method, 'stop');
    expect(Hive.box('vault_box').get('background_protection'), isFalse);

    calls.clear();
    expect(await ProtectionService.startIfEnabled(), isFalse);
    expect(calls, isEmpty);

    await ProtectionService.init(); // the next app start reads it back
    expect(ProtectionService.enabled.value, isFalse);
  });

  test('turning it back on starts it again', () async {
    await ProtectionService.setEnabled(false);
    calls.clear();
    await ProtectionService.setEnabled(true);
    expect(calls.single.method, 'start');
  });

  test('disguise mode switches the notification wording and starts disguised', () async {
    DisguiseService.enabled.value = true;
    expect(calls.single.method, 'setDisguised');
    expect(calls.single.arguments, {'disguised': true});

    calls.clear();
    await ProtectionService.startIfEnabled();
    expect(calls.single.arguments, {'disguised': true});
  });

  test('a refusal from Android is reported, not thrown', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'protection_failed', message: 'ForegroundServiceStartNotAllowedException');
    });
    expect(await ProtectionService.startIfEnabled(), isFalse);
  });

  test('without the Android side (other platforms) it is a no-op', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await ProtectionService.startIfEnabled(), isFalse);
    expect(await ProtectionService.isRunning(), isFalse);
  });
}
