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
      onDistressDetected: _handleAIDistressDetected,
    );
  }

  static Future<void> simulateAIDistressDetection() async {
    developer.log(
      'Manual demo distress simulation requested.',
      name: 'JusticeChain.Controller',
    );
    await _aiService.simulateDistressDetection();
  }

  static Future<void> _handleAIDistressDetected(AIDistressEvent event) async {
    final confidencePercent = (event.confidence * 100).toStringAsFixed(0);

    // 1. CRITICAL CONCURRENCY GUARD: Instantly drop processing if system is already recording
    if (isRecording.value || (cameraController != null && cameraController!.value.isRecordingVideo)) {
      developer.log(
        'AI trigger ignored because an emergency recording is already active.',
        name: 'JusticeChain.Controller',
      );
      return;
    }

    developer.log(
      'AI distress detected (${event.label}, $confidencePercent%). Processing system initialization...',
      name: 'JusticeChain.Controller',
    );

    if (cameraController == null || !cameraController!.value.isInitialized) {
      appStatus.value = 'AI detected distress, but camera is not ready';
      developer.log(
        'AI trigger ignored because the camera hardware is not initialized.',
        name: 'JusticeChain.Controller',
      );
      return;
    }

    // 2. PAUSE MICROPHONE STREAM FIRST: Avoids hardware device lock leaks with camera audio tracks
    await _aiService.pauseForRecording();

    appStatus.value =
        'AI distress detected ($confidencePercent%). Recording evidence...';

    try {
      await startRecording();
      
      developer.log(
        'AI trigger successfully engaged video+audio emergency recording channels.',
        name: 'JusticeChain.Controller',
      );
      
      // Keep this visible in Android logcat during Review-2 device demos.
      // ignore: avoid_print
      print('JusticeChain.Controller: AI trigger started emergency recording');
    } catch (e) {
      developer.log(
        'Failed to engage recording layers via AI trigger: $e',
        name: 'JusticeChain.Controller',
        error: e,
      );
      // Fallback: Attempt to resume monitoring if hardware activation fails
      await _aiService.resumeAfterRecording();
    }
  }

  // --- HARDWARE CAMERA CHANNELS ---

  static Future<void> startRecording() async {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      return;
    }
    if (cameraController!.value.isRecordingVideo) return;

    // Double check that the AI stream has paused monitoring before starting
    await _aiService.pauseForRecording();
    
    try {
      await cameraController!.startVideoRecording();
      isRecording.value = true;
    } catch (_) {
      await _aiService.resumeAfterRecording();
      rethrow;
    }
  }

  static dynamic stopRecording() async {
    if (cameraController == null || !cameraController!.value.isRecordingVideo) {
      return null;
    }
    final video = await cameraController!.stopVideoRecording();
    isRecording.value = false;
    
    // Safely re-engages microphone polling after file pointers are generated
    await _aiService.resumeAfterRecording();
    return video;
  }

  static Future<void> shutdownMonitoring() async {
    await _aiService.dispose();
  }
}