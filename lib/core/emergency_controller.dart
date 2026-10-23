import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'ai_service.dart';
import 'disguise_service.dart';
import 'evidence_vault_service.dart';
import 'mesh_service.dart';
import 'protection_service.dart';
import '../logic/safety_signals.dart';

class EmergencyController {
  static final AIService _aiService = AIService.instance;

  /// Global access reference to sync UI triggers.
  static dynamic cameraController;

  /// A clip must survive the phone being switched off or the recording UI
  /// being disposed during or right after an incident, so this failsafe
  /// lives here rather than in a screen's State, which would stop firing
  /// the moment the widget tree is torn down or the screen locks.
  static const Duration recordingTimeout = Duration(seconds: 45);
  static Timer? _recordingTimeoutTimer;

  /// Bootstraps localized AI screening routines.
  static Future<void> startBackgroundMonitoring() async {
    _monitoringWanted = true;
    if (!_listeningRuleWired) {
      _listeningRuleWired = true;
      DisguiseService.enabled.addListener(_applyListeningRule);
      ProtectionService.listenWhileDisguised.addListener(_applyListeningRule);
    }
    await _applyListeningRule();
  }

  static bool _monitoringWanted = false;
  static bool _listeningRuleWired = false;

  /// The user's "Keep listening while disguised" switch: with it off,
  /// nothing listens while the calculator disguise is on (no microphone
  /// dot); only "112 =" or the SOS button records then.
  static bool get listeningAllowed =>
      !(DisguiseService.enabled.value && !ProtectionService.listenWhileDisguised.value);

  static Future<void> _applyListeningRule() async {
    if (!_monitoringWanted) return;
    if (listeningAllowed) {
      await _aiService.startMonitoring(onDistressDetected: _handleDistress);
      // Keeps listening after the screen locks or the app is swiped away.
      // Started here because monitoring starts while the app is on screen.
      await ProtectionService.startIfEnabled();
    } else if (!isRecording.value) {
      await ProtectionService.stop();
      await _aiService.stopMonitoring(status: 'AI paused while disguised');
    }
  }

  static Future<void> _handleDistress(AIDistressEvent event) async {
    final confidencePercent = (event.confidence * 100).toStringAsFixed(0);

    // Update operational AI signals instantly for the UI layout
    aiPrediction.value = event.label;
    aiConfidence.value = event.confidence;
    aiStatus.value = "AI Monitoring: ${event.label} ($confidencePercent%)";

    // CRITICAL: Single Point of Entry Guard
    // If we are already recording, ignore incoming duplicate triggers
    if (isRecording.value ||
        (cameraController != null &&
            cameraController!.value.isRecordingVideo)) {
      return;
    }

    if (_backgroundRecording) return;

    if (event.label.toLowerCase() == 'distress') {
      developer.log(
        '🔥 AI Brain verified distress status ($confidencePercent%). Firing reactive safety signal.',
        name: 'JusticeChain.Controller',
      );
      if (_holdsCamera) {
        // The app is on screen: the home screen records with its camera.
        aiDistressDetected.value = true;
      } else {
        // Locked, in the background or swiped away: the home screen has
        // let the camera go, so record natively.
        unawaited(startBackgroundRecording());
      }
    }
  }

  static bool get _holdsCamera =>
      cameraController != null && cameraController!.value.isInitialized as bool;

  static bool _backgroundRecording = false;

  /// Whether a native background recording is running (the home screen's
  /// stop button ends it through [stopRecording]).
  static bool get isBackgroundRecording => _backgroundRecording;

  /// Seals a finished clip; tests swap it for a fake.
  @visibleForTesting
  static Future<void> Function(String path) sealClip = EvidenceVaultService.sealAndUpload;

  /// Records with the native recorder while the app isn't on screen (step
  /// 6b): video, or audio only if the camera can't be used, for up to
  /// [recordingTimeout]. Then listening resumes and the clip is sealed and
  /// uploaded like any other.
  static Future<void> startBackgroundRecording() async {
    if (_backgroundRecording || isRecording.value) return;
    _backgroundRecording = true;
    BackgroundClip? clip;
    try {
      // The recorder needs the microphone the AI is using.
      await _aiService.pauseForRecording();
      isRecording.value = true;
      appStatus.value = "RECORDING EVIDENCE...";
      unawaited(MeshService.startAdvertising());
      developer.log('🎬 Background recording started.', name: 'JusticeChain.Controller');

      clip = await ProtectionService.recordInBackground(recordingTimeout);
    } finally {
      isRecording.value = false;
      _backgroundRecording = false;
      await _aiService.resumeAfterRecording();
    }

    if (clip == null) {
      appStatus.value = "Recording failed";
      return;
    }
    developer.log(
      'Background ${clip.audioOnly ? 'audio' : 'video'} clip finished: ${clip.path}',
      name: 'JusticeChain.Controller',
    );
    await sealClip(clip.path);
  }

  static Future<void> simulateAIDistressDetection() async {
    developer.log(
      'Manual demo distress simulation requested.',
      name: 'JusticeChain.Controller',
    );
    await _aiService.simulateDistressDetection();
  }

  // --- HARDWARE CAMERA CHANNELS ---

  static Future<void> startRecording() async {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      developer.log(
        'Recording aborted: Camera hardware reference is missing or uninitialized.',
        name: 'JusticeChain.Controller',
      );
      return;
    }
    if (cameraController!.value.isRecordingVideo) return;

    try {
      // 1. Pause microphone streaming first to avoid OS-level device lock leaks with video audio track
      await _aiService.pauseForRecording();

      // 2. Fire hardware implementation
      await cameraController!.startVideoRecording();

      // 3. Update states sequentially to update UI widgets
      isRecording.value = true;
      appStatus.value = "RECORDING EVIDENCE...";

      // Become visible to nearby guardians now, so a link is already up
      // by the time the clip is sealed and queued for relay.
      unawaited(MeshService.startAdvertising());

      // 4. Arm the failsafe: if nothing stops the recording first, this
      // fires on its own and seals whatever was captured so far.
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = Timer(recordingTimeout, _handleRecordingTimeout);

      developer.log(
        '🎬 Emergency recording channels successfully locked and active.',
        name: 'JusticeChain.Controller',
      );
    } catch (e) {
      developer.log(
        'Failed to engage native camera recording layer: $e',
        name: 'JusticeChain.Controller',
        error: e,
      );
      // Fallback recovery: Ensure monitoring resumes if native camera deployment crashes
      await _aiService.resumeAfterRecording();
      rethrow;
    }
  }

  static dynamic stopRecording() async {
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;

    if (_backgroundRecording) {
      // startBackgroundRecording gets the clip and seals it.
      await ProtectionService.stopRecording();
      return null;
    }

    if (cameraController == null || !cameraController!.value.isRecordingVideo) {
      return null;
    }

    try {
      final video = await cameraController!.stopVideoRecording();
      isRecording.value = false;

      // Safely re-engages microphone polling after file pointers are completely generated
      await _aiService.resumeAfterRecording();
      return video;
    } catch (e) {
      developer.log(
        'Failed to cleanly stop camera recording layers: $e',
        name: 'JusticeChain.Controller',
        error: e,
      );
      isRecording.value = false;
      await _aiService.resumeAfterRecording();
      return null;
    }
  }

  /// Fires if nothing calls stopRecording within [recordingTimeout]. Unlike
  /// a timer owned by a screen's State, this keeps running whether or not
  /// any UI is currently mounted to watch it, and seals the clip itself
  /// instead of merely notifying a widget that may no longer exist.
  static Future<void> _handleRecordingTimeout() async {
    developer.log(
      '⏱️ AUTOMATIC TIMEOUT: ${recordingTimeout.inSeconds}s reached. Sealing captured evidence...',
      name: 'JusticeChain.Controller',
    );

    final video = await stopRecording();
    if (video == null) return;

    await EvidenceVaultService.sealAndUpload(video.path as String);
  }

  static Future<void> shutdownMonitoring() async {
    _monitoringWanted = false;
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;
    await ProtectionService.stop();
    await _aiService.dispose();
  }
}
