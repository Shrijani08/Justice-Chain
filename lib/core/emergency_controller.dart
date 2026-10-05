import 'dart:async';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'evidence_vault_service.dart';
import 'mesh_service.dart';
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
    await _aiService.startMonitoring(
      onDistressDetected: (AIDistressEvent event) async {
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

        // If the AI confirms a valid distress event, flip the signal to let the UI effect handle it cleanly
        if (event.label.toLowerCase() == 'distress') {
          developer.log(
            '🔥 AI Brain verified distress status ($confidencePercent%). Firing reactive safety signal.',
            name: 'JusticeChain.Controller',
          );
          aiDistressDetected.value = true;
        }
      },
    );
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
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;
    await _aiService.dispose();
  }
}
