import 'dart:developer' as developer;
import 'ai_service.dart';
import '../logic/safety_signals.dart';

class EmergencyController {
  static final AIService _aiService = AIService.instance;

  /// Global access reference to sync UI triggers.
  static dynamic cameraController;

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

  static Future<void> shutdownMonitoring() async {
    await _aiService.dispose();
  }
}
