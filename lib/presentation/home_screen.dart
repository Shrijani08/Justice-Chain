import 'dart:io';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import '../logic/safety_signals.dart';
import '../core/app_services.dart';

class MainSafetyScreen extends StatefulWidget {
  const MainSafetyScreen({super.key});

  @override
  State<MainSafetyScreen> createState() => _MainSafetyScreenState();
}

class _MainSafetyScreenState extends State<MainSafetyScreen> {
  CameraController? _cameraController;

  @override
  void initState() {
    super.initState();
    _initPermissions();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  // --- PERMISSIONS & INITIALIZATION ---

  Future<void> _initPermissions() async {
    logger.i("Requesting Permissions...");
    appStatus.value = "Checking Permissions...";

    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.location,
    ].request();

    if (statuses[Permission.camera]!.isGranted && 
        statuses[Permission.microphone]!.isGranted) {
      logger.i("Permissions Granted.");
      await _initializeCamera();
    } else {
      logger.w("Permissions Denied.");
      appStatus.value = "System Error: Permissions Denied";
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        _cameraController = CameraController(
          cameras[0],
          ResolutionPreset.high,
          enableAudio: true,
        );

        await _cameraController!.initialize();
        cameraReady.value = true;
        appStatus.value = "System Ready: Monitoring Active";
        logger.i("Camera Hardware Initialized.");
      }
    } catch (e) {
      logger.e("Camera Initialization Failed: $e");
      appStatus.value = "Camera Error: $e";
    }
  }

  // --- RECORDING LOGIC ---

  Future<void> startEmergencyRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      logger.e("Recording failed: Camera not initialized");
      return;
    }
    try {
      await _cameraController!.startVideoRecording();
      isRecording.value = true;
      appStatus.value = "⚠️ RECORDING EVIDENCE...";
      logger.w("Emergency Recording Started!");
    } catch (e) {
      logger.e("Failed to start recording: $e");
    }
  }

  Future<void> stopEmergencyRecording() async {
    if (_cameraController == null || !_cameraController!.value.isRecordingVideo) return;
    try {
      XFile videoFile = await _cameraController!.stopVideoRecording();
      isRecording.value = false;
      await _secureEvidence(videoFile.path);
      logger.i("Recording Saved to: ${videoFile.path}");
    } catch (e) {
      logger.e("Failed to stop: $e");
    }
  }

  // --- SECURITY & CACHING (THE VAULT) ---

  Future<void> _secureEvidence(String filePath) async {
    try {
      appStatus.value = "Sealing Evidence...";
      
      // Calculate SHA-256 Hash
      final bytes = await File(filePath).readAsBytes();
      final hash = sha256.convert(bytes).toString();
      
      // Store metadata in Hive
      var vaultBox = Hive.box('vault_box');
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
    var vaultBox = Hive.box('vault_box');
    logger.i("--- VAULT CONTENTS (${vaultBox.length} items) ---");
    
    for (var i = 0; i < vaultBox.length; i++) {
      final data = vaultBox.getAt(i);
      logger.d("Item $i: Hash: ${data['hash'].toString().substring(0, 15)}... | Path: ${data['path']}");
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentStatus = appStatus.watch(context);
    final isRecordingActive = isRecording.watch(context);
    final isReady = cameraReady.watch(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Justice-Chain Sentinel"),
        backgroundColor: Colors.red.shade100,
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Status Icon
            Icon(
              isRecordingActive ? Icons.fiber_manual_record : Icons.security,
              size: 100,
              color: isRecordingActive ? Colors.red : (isReady ? Colors.green : Colors.grey),
            ),
            const SizedBox(height: 30),
            
            // Status Text
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                currentStatus,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 50),

            // Control Buttons
            if (isReady) ...[
              ElevatedButton.icon(
                onPressed: isRecordingActive ? stopEmergencyRecording : startEmergencyRecording,
                icon: Icon(isRecordingActive ? Icons.stop : Icons.videocam),
                label: Text(isRecordingActive ? "STOP RECORDING" : "START TEST RECORD"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRecordingActive ? Colors.black : Colors.red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(220, 60),
                ),
              ),
              const SizedBox(height: 20),
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
    );
  }
}