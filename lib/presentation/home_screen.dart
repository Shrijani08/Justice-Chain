import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/app_services.dart';
import '../core/emergency_controller.dart';
import '../logic/safety_signals.dart';

class MainSafetyScreen extends StatefulWidget {
  const MainSafetyScreen({super.key});

  @override
  State<MainSafetyScreen> createState() => _MainSafetyScreenState();
}

class _MainSafetyScreenState extends State<MainSafetyScreen> {
  CameraController? _cameraController;
  bool _isProcessingSave = false;

  @override
  void initState() {
    super.initState();
    _initPermissions();
  }

  @override
  void dispose() {
    unawaited(EmergencyController.shutdownMonitoring());
    _cameraController?.dispose();
    super.dispose();
  }

  // --- PERMISSIONS & INITIALIZATION ---

  Future<void> _initPermissions() async {
    logger.i("Requesting Permissions...");
    appStatus.value = "Checking Permissions...";

    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.location,
    ].request();

    final hasCameraPermission = statuses[Permission.camera]?.isGranted ?? false;
    final hasMicrophonePermission =
        statuses[Permission.microphone]?.isGranted ?? false;

    if (hasMicrophonePermission) {
      logger.i("Microphone Permission Granted.");
      await EmergencyController.startBackgroundMonitoring();
    }

    if (hasCameraPermission && hasMicrophonePermission) {
      logger.i("Camera Permission Granted.");
      await _initializeCamera();
    } else {
      logger.w("Permissions Denied.");
      appStatus.value = hasMicrophonePermission
          ? "AI Monitoring Active: Camera Permission Denied"
          : "System Error: Microphone Permission Denied";
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        appStatus.value = "Camera Error: No camera found";
        return;
      }

      Object? lastError;
      for (final camera in cameras) {
        final controller = CameraController(
          camera,
          ResolutionPreset.high,
          enableAudio: true,
        );

        try {
          await controller.initialize();
          _cameraController = controller;
          EmergencyController.cameraController = _cameraController;
          cameraReady.value = true;
          appStatus.value = "System Ready: AI + Camera Monitoring Active";
          logger.i("Camera Hardware Initialized: ${camera.name}");
          return;
        } catch (e) {
          lastError = e;
          await controller.dispose();
          logger.w("Camera ${camera.name} unavailable: $e");
        }
      }

      throw lastError ?? "No usable camera found";
    } catch (e) {
      logger.e("Camera Initialization Failed: $e");
      cameraReady.value = false;
      appStatus.value = "AI Listening: Camera Error: $e";
    }
  }

  // --- RECORDING LOGIC ---

  Future<void> startEmergencyRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      logger.e("Recording failed: Camera not initialized");
      return;
    }
    if (isRecording.value) return;

    try {
      await EmergencyController.startRecording();
      isRecording.value = true;
      appStatus.value = "RECORDING EVIDENCE...";
      logger.w("Emergency Recording Started!");
    } catch (e) {
      logger.e("Failed to start recording: $e");
    }
  }

  Future<void> stopEmergencyRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isRecordingVideo) {
      return;
    }
    if (_isProcessingSave) return;

    setState(() {
      _isProcessingSave = true;
    });

    try {
      final tempVideo = await EmergencyController.stopRecording();
      if (tempVideo == null) {
        setState(() {
          _isProcessingSave = false;
        });
        return;
      }

      isRecording.value = false;

      final directory = await getApplicationDocumentsDirectory();
      final vaultDir = Directory('${directory.path}/JusticeChain');

      if (!await vaultDir.exists()) {
        await vaultDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newPath = '${vaultDir.path}/evidence_$timestamp.mp4';

      final savedFile = await File(tempVideo.path).copy(newPath);
      await File(tempVideo.path).delete();

      await _secureEvidence(savedFile.path);

      logger.i("Evidence Saved Permanently:");
      logger.i(savedFile.path);

      appStatus.value = "Evidence Secured in JusticeChain Vault";
    } catch (e) {
      logger.e("Failed to stop recording: $e");
      appStatus.value = "Recording Save Failed";
    } finally {
      setState(() {
        _isProcessingSave = false;
      });
    }
  }

  // --- SECURITY & CACHING (THE VAULT) ---

  Future<void> _secureEvidence(String filePath) async {
    try {
      appStatus.value = "Sealing Evidence...";

      final bytes = await File(filePath).readAsBytes();
      final hash = sha256.convert(bytes).toString();

      final vaultBox = Hive.box('vault_box');
      await vaultBox.add({
        'path': filePath,
        'hash': hash,
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'locally_secured',
      });

      logger.i("Fingerprint Generated: $hash");
      appStatus.value = "Evidence Secured & Fingerprinted.";
    } catch (e) {
      logger.e("Securing evidence failed: $e");
      appStatus.value = "Security Error: Hash Failed";
    }
  }

  // --- DEBUG TOOLS ---

  void _debugPrintVault() {
    final vaultBox = Hive.box('vault_box');
    logger.i("=== MANUAL VAULT CHECK (${vaultBox.length} items) ===");

    for (var i = 0; i < vaultBox.length; i++) {
      final data = vaultBox.getAt(i);
      if (data != null && data['hash'] != null) {
        final fullHash = data['hash'].toString();
        final displayHash = fullHash.length > 15
            ? fullHash.substring(0, 15)
            : fullHash;
        logger.d("Item $i: Hash: $displayHash... | Path: ${data['path']}");
      } else {
        logger.w("Item $i: Corrupted or null vault entry data.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentStatus = appStatus.watch(context);
    final isRecordingActive = isRecording.watch(context);
    final isReady = cameraReady.watch(context);
    final currentAiStatus = aiStatus.watch(context);
    final currentAiConfidence = aiConfidence.watch(context);
    final isAiReady = aiModelReady.watch(context);
    final isAiActive = aiActive.watch(context);
    final currentAiPrediction = aiPrediction.watch(context);
    final isDistressDetected = aiDistressDetected.watch(context);
    final aiConfidencePercent = (currentAiConfidence * 100).toStringAsFixed(0);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Justice-Chain Sentinel"),
        backgroundColor: Colors.red.shade100,
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isRecordingActive ? Icons.fiber_manual_record : Icons.security,
                size: 100,
                color: isRecordingActive
                    ? Colors.red
                    : (isReady ? Colors.green : Colors.grey),
              ),
              const SizedBox(height: 30),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  currentStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 280,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isDistressDetected
                              ? Icons.warning_amber
                              : (isAiActive
                                    ? Icons.hearing
                                    : Icons.psychology_alt),
                          color: isDistressDetected
                              ? Colors.red
                              : (isAiActive ? Colors.green : Colors.grey),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            currentAiStatus,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          isAiReady ? "Model ready" : "Model loading",
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isAiActive ? "Listening" : "Idle",
                          style: TextStyle(
                            fontSize: 13,
                            color: isAiActive ? Colors.green : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Prediction: $currentAiPrediction",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isDistressDetected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isDistressDetected ? Colors.red : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: currentAiConfidence,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                      backgroundColor: Colors.grey.shade300,
                      color: currentAiConfidence >= 0.85
                          ? Colors.red
                          : Colors.green,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "AI confidence: $aiConfidencePercent%",
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              if (isReady) ...[
                ElevatedButton.icon(
                  onPressed: _isProcessingSave
                      ? null
                      : () {
                          if (isRecordingActive) {
                            stopEmergencyRecording();
                          } else {
                            startEmergencyRecording();
                          }
                        },
                  icon: Icon(isRecordingActive ? Icons.stop : Icons.videocam),
                  label: Text(
                    _isProcessingSave
                        ? "SAVING TO VAULT..."
                        : (isRecordingActive
                              ? "STOP RECORDING"
                              : "START TEST RECORD"),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRecordingActive
                        ? Colors.black
                        : Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(220, 60),
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _isProcessingSave || isRecordingActive
                      ? null
                      : () async {
                          logger.w("Demo AI distress trigger pressed.");
                          await EmergencyController.simulateAIDistressDetection();
                        },
                  icon: const Icon(Icons.warning_amber),
                  label: const Text("Debug: Simulate AI Distress"),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _debugPrintVault,
                  icon: const Icon(Icons.storage),
                  label: const Text("Debug: Print Vault Contents"),
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed: _initPermissions,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Initialize System"),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
