import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/emergency_controller.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/protection_service.dart';
import 'package:justice_chain/logic/safety_signals.dart';

/// Step 6b phase 2: recording natively while the app isn't on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('in.sakshya/protection');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late List<MethodCall> calls;
  late List<String> sealed;
  // What the fake recorder answers 'record' with; completed by the test.
  late Completer<Object?> recordAnswer;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('background_recording_test');
    Hive.init(tempDir.path);
    await Hive.openBox('vault_box');
    FlutterSecureStorage.setMockInitialValues({});
    await IdentityService.initializeDevice(); // the mesh asks for the node ID
    // The AI's microphone plugin: present, but never streaming here.
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'), (call) async => null);
  });

  setUp(() {
    calls = [];
    sealed = [];
    recordAnswer = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'record') return recordAnswer.future;
      if (call.method == 'stopRecording') {
        if (!recordAnswer.isCompleted) recordAnswer.complete({'path': '/cache/stopped.mp4', 'kind': 'video'});
      }
      return true;
    });
    EmergencyController.sealClip = (path) async => sealed.add(path);
    EmergencyController.cameraController = null; // the app isn't on screen
    isRecording.value = false;
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  tearDownAll(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
  });

  group('ProtectionService.recordInBackground', () {
    test('asks for the 45 s limit and returns the video clip', () async {
      recordAnswer.complete({'path': '/cache/background_1.mp4', 'kind': 'video'});
      final clip = await ProtectionService.recordInBackground(const Duration(seconds: 45));
      expect(calls.single.method, 'record');
      expect(calls.single.arguments, {'seconds': 45});
      expect(clip!.path, '/cache/background_1.mp4');
      expect(clip.audioOnly, isFalse);
    });

    test('marks an audio-only fallback', () async {
      recordAnswer.complete({'path': '/cache/background_2.mp4', 'kind': 'audio'});
      final clip = await ProtectionService.recordInBackground(const Duration(seconds: 45));
      expect(clip!.audioOnly, isTrue);
    });

    test('returns null when nothing could be recorded', () async {
      recordAnswer.complete({'error': 'microphone permission missing'});
      expect(await ProtectionService.recordInBackground(const Duration(seconds: 45)), isNull);
    });

    test('returns null on other platforms', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await ProtectionService.recordInBackground(const Duration(seconds: 45)), isNull);
    });
  });

  group('EmergencyController.startBackgroundRecording', () {
    test('marks recording while it runs, then seals the clip', () async {
      final run = EmergencyController.startBackgroundRecording();
      await pumpEventQueue();
      expect(isRecording.value, isTrue);
      expect(EmergencyController.isBackgroundRecording, isTrue);

      recordAnswer.complete({'path': '/cache/background_3.mp4', 'kind': 'video'});
      await run;
      expect(isRecording.value, isFalse);
      expect(EmergencyController.isBackgroundRecording, isFalse);
      expect(sealed, ['/cache/background_3.mp4']);
    });

    test('a second trigger while recording starts nothing', () async {
      final run = EmergencyController.startBackgroundRecording();
      await pumpEventQueue();
      await EmergencyController.startBackgroundRecording();
      expect(calls.where((c) => c.method == 'record'), hasLength(1));

      recordAnswer.complete({'path': '/cache/background_4.mp4', 'kind': 'audio'});
      await run;
      expect(sealed, ['/cache/background_4.mp4']);
    });

    test('the stop button ends it early and the clip is still sealed', () async {
      final run = EmergencyController.startBackgroundRecording();
      await pumpEventQueue();
      expect(await EmergencyController.stopRecording(), isNull);
      await run;
      expect(calls.map((c) => c.method), contains('stopRecording'));
      expect(sealed, ['/cache/stopped.mp4']);
    });

    test('a failed recording seals nothing and clears the recording state', () async {
      final run = EmergencyController.startBackgroundRecording();
      await pumpEventQueue();
      recordAnswer.complete({'error': 'audio recording failed'});
      await run;
      expect(sealed, isEmpty);
      expect(isRecording.value, isFalse);
      expect(appStatus.value, 'Recording failed');
    });
  });
}
