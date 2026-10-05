import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/app_services.dart';
import '../core/emergency_controller.dart';
import '../core/evidence_vault_service.dart';
import '../core/mesh_service.dart';
import '../logic/safety_signals.dart';
import 'evidence_viewer_screen.dart';
import 'guardian_evidence_screen.dart';
import 'guardian_pairing_screen.dart';
import 'guardian_scanner_screen.dart';

class MainSafetyScreen extends StatefulWidget {
  const MainSafetyScreen({super.key});

  @override
  State<MainSafetyScreen> createState() => _MainSafetyScreenState();
}

class _MainSafetyScreenState extends State<MainSafetyScreen> {
  CameraController? _cameraController;
  bool _isProcessingSave = false;
  EffectCleanup? _distressEffectCleanup;

  @override
  void initState() {
    super.initState();
    _initPermissions();
    _setupAutomaticTrigger();
  }

  void _setupAutomaticTrigger() {
    _distressEffectCleanup = effect(() {
      final isDistressed = aiDistressDetected.value;
      final isReady = cameraReady.value;
      final recordingNow = isRecording.value;

      if (isDistressed && isReady && !recordingNow) {
        logger.w(
          "🔥 AUTOMATIC TRIGGER: Distress detected by AI! Starting camera recording.",
        );
        aiDistressDetected.value = false;
        unawaited(startEmergencyRecording());
      }
    });
  }

  @override
  void dispose() {
    _distressEffectCleanup?.call();
    unawaited(EmergencyController.shutdownMonitoring());
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initPermissions() async {
    logger.i("Requesting Permissions...");
    appStatus.value = "Checking Permissions...";

    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();

    // Listen for paired contacts in distress while the app is open, so
    // this phone can act as their guardian relay.
    final canUseMesh = (statuses[Permission.location]?.isGranted ?? false) ||
        (statuses[Permission.bluetoothScan]?.isGranted ?? false);
    if (canUseMesh) {
      await MeshService.startDiscovery();
    } else {
      logger.w("Nearby permissions denied: offline guardian relay disabled.");
    }

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
          ResolutionPreset.medium,
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

  Future<void> startEmergencyRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      logger.e("Recording failed: Camera not initialized");
      return;
    }
    if (isRecording.value) return;

    try {
      // EmergencyController owns both the hardware recording call and the
      // 45-second failsafe timer, so the failsafe keeps running even if
      // this screen is disposed or the device screen locks mid-recording.
      await EmergencyController.startRecording();
      isRecording.value = true;
      appStatus.value = "RECORDING EVIDENCE...";
      logger.w("Emergency Recording Started!");
    } catch (e) {
      logger.e("Failed to start recording: $e");
    }
  }

  /// Manual "STOP RECORDING" button path. The automatic 45-second timeout
  /// path runs independently through EmergencyController and
  /// EvidenceVaultService, with no dependency on this screen being mounted.
  Future<void> stopEmergencyRecording() async {
    if (_cameraController == null ||
        !_cameraController!.value.isRecordingVideo) {
      return;
    }
    if (_isProcessingSave) return;

    if (mounted) {
      setState(() {
        _isProcessingSave = true;
      });
    } else {
      _isProcessingSave = true;
    }

    try {
      final tempVideo = await EmergencyController.stopRecording();
      if (tempVideo == null) {
        return;
      }

      isRecording.value = false;
      aiDistressDetected.value = false;

      await EvidenceVaultService.sealAndUpload(tempVideo.path as String);
    } catch (e) {
      logger.e("Failed to stop recording: $e");
      appStatus.value = "Recording Save Failed";
    } finally {
      _isProcessingSave = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  // --- DEBUG TOOLS ---

  void _debugPrintVault() {
    final vaultBox = Hive.box('vault_box');
    final entries = vaultBox.toMap();
    logger.i("=== MANUAL VAULT CHECK (${entries.length} items) ===");

    entries.forEach((key, data) {
      // Evidence records are keyed by content hash and carry a 'status'
      // field; other box entries (e.g. the trusted-guardians map) are not
      // evidence records and are skipped here rather than misreported.
      if (data is Map && data['status'] != null) {
        final fullHash = (data['hash'] ?? key).toString();
        final displayHash = fullHash.length > 15
            ? fullHash.substring(0, 15)
            : fullHash;
        final cid = data['cid'] ?? 'Pending/None';
        logger.d(
          "Key $key: Hash: $displayHash... | CID: $cid | Path: ${data['path']}",
        );
      }
    });
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
                // The manual SOS path: it calls startEmergencyRecording()
                // directly, bypassing the AI model and its 2-of-3 confirmation
                // window entirely. A victim who can act must never depend on
                // the model being right or fast enough.
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
                              : "SOS — START RECORDING"),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRecordingActive
                        ? Colors.black
                        : Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(220, 60),
                  ),
                ),
                // Debug-only affordances: a stray tap on these in the field
                // could fire a false emergency upload, and they advertise
                // exactly how the app works to anyone holding the phone, so
                // they must never ship in a release build.
                if (kDebugMode) ...[
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
                ],
                const SizedBox(height: 12),

                // Guardian Pairing Controls Side-by-Side
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const GuardianPairingScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Show My QR'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const GuardianScannerScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan QR'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const EvidenceViewerScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.video_library),
                  label: const Text('My Evidence'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const GuardianEvidenceScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.shield),
                  label: const Text('Guardian Evidence'),
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
