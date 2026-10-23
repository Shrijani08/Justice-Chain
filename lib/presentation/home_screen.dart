import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/app_services.dart';
import '../core/disguise_service.dart';
import '../core/emergency_controller.dart';
import '../core/yamnet_detector.dart';
import '../core/evidence_vault_service.dart';
import '../core/mesh_service.dart';
import '../core/protection_service.dart';
import '../logic/safety_signals.dart';
import 'design/components.dart';
import 'design/sentinel.dart';
import 'design/tokens.dart';
import 'evidence_viewer_screen.dart';
import 'guardian_evidence_screen.dart';
import 'guardian_pairing_screen.dart';
import 'guardian_scanner_screen.dart';
import 'guardians_screen.dart';

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
      final quickSos = sosRequested.value;
      final isReady = cameraReady.value;
      final recordingNow = isRecording.value;

      if (quickSos && recordingNow) {
        sosRequested.value = false; // already recording
      } else if ((isDistressed || quickSos) && isReady && !recordingNow) {
        logger.w(
          quickSos
              ? "🔥 QUICK SOS from the disguise calculator. Starting camera recording."
              : "🔥 AUTOMATIC TRIGGER: Distress detected by AI! Starting camera recording.",
        );
        aiDistressDetected.value = false;
        sosRequested.value = false;
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
      Permission.notification, // background protection's notification
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

  /// Hands the camera back to the OS so another screen (the QR scanner) can
  /// open it. The home screen's controller would otherwise be closed under it
  /// and keep reporting itself as initialized.
  Future<void> _releaseCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    EmergencyController.cameraController = null;
    cameraReady.value = false;
    await controller?.dispose();
  }

  Future<void> _restartCamera() async {
    await _releaseCamera();
    await _initializeCamera();
  }

  /// Opens a screen that needs the camera itself, then takes it back.
  Future<void> _openCameraScreen(Widget screen) async {
    if (isRecording.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stop the recording first.')),
      );
      return;
    }
    await _releaseCamera();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => screen),
    );
    if (mounted) await _initializeCamera();
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
      try {
        await EmergencyController.startRecording();
      } catch (e) {
        // The OS can close the camera under us (another app, screen lock),
        // leaving a controller that still claims to be initialized. Reopen
        // it once and retry rather than losing the recording.
        logger.w("Recording failed to start ($e). Restarting camera and retrying.");
        await _restartCamera();
        if (_cameraController == null) rethrow;
        await EmergencyController.startRecording();
      }
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


  void _push(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => screen));
  }

  SentinelState _sentinelState({
    required bool recording,
    required bool distress,
    required bool listening,
    required bool modelReady,
  }) {
    if (_isProcessingSave) return SentinelState.saving;
    if (recording) return SentinelState.recording;
    if (distress) return SentinelState.alert;
    if (listening) return SentinelState.listening;
    if (!modelReady) return SentinelState.starting;
    return SentinelState.offline;
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
    final c = context.sak;

    final state = _sentinelState(
      recording: isRecordingActive,
      distress: isDistressDetected,
      listening: isAiActive,
      modelReady: isAiReady,
    );

    return SakPage(
      title: 'Sakshya',
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The live state: the seal, what the system says, and what is on.
              Reveal(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(SakSpace.gutter, SakSpace.sm, SakSpace.gutter, 0),
                  child: Column(
                    children: [
                      SentinelOrb(state: state, level: currentAiConfidence),
                      const SizedBox(height: SakSpace.lg),
                      AnimatedSwitcher(
                        duration: SakMotion.of(context, SakMotion.quick),
                        child: Text(
                          currentStatus,
                          key: ValueKey(currentStatus),
                          textAlign: TextAlign.center,
                          style: context.type.bodyMedium?.copyWith(color: c.inkSecondary),
                        ),
                      ),
                      const SizedBox(height: SakSpace.md),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: SakSpace.sm,
                        runSpacing: SakSpace.sm,
                        children: [
                          StatusPill(
                            label: isAiActive ? 'Listening' : 'Idle',
                            color: isAiActive ? c.success : c.inkSecondary,
                            pulsing: isAiActive,
                          ),
                          StatusPill(
                            label: isAiReady ? 'Model ready' : 'Model loading',
                            color: isAiReady ? c.success : c.inkSecondary,
                            icon: isAiReady ? Icons.check_rounded : Icons.downloading_rounded,
                          ),
                          StatusPill(
                            label: isReady ? 'Camera ready' : 'Camera off',
                            color: isReady ? c.success : c.warning,
                            icon: isReady ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: SakSpace.xl),

              if (isReady)
                // The manual SOS path: it calls startEmergencyRecording()
                // directly, bypassing the AI model and its 2-of-3 confirmation
                // window entirely. A victim who can act must never depend on
                // the model being right or fast enough.
                Reveal(
                  index: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: SakSpace.gutter),
                    child: SakButton(
                      label: _isProcessingSave
                          ? 'Sealing to Vault…'
                          : (isRecordingActive ? 'Stop Recording' : 'SOS · Start Recording'),
                      icon: isRecordingActive ? Icons.stop_rounded : Icons.videocam_rounded,
                      style: isRecordingActive ? SakButtonStyle.dangerTinted : SakButtonStyle.danger,
                      loading: _isProcessingSave,
                      onPressed: _isProcessingSave
                          ? null
                          : () {
                              if (isRecordingActive) {
                                stopEmergencyRecording();
                              } else {
                                startEmergencyRecording();
                              }
                            },
                    ),
                  ),
                )
              else
                Reveal(
                  index: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: SakSpace.gutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SakNotice(
                          tone: NoticeTone.warning,
                          title: 'Recording is not ready',
                          message: 'Sakshya needs the camera and microphone to record evidence. '
                              'Allow both, then start protection.',
                        ),
                        const SizedBox(height: SakSpace.md),
                        SakButton(
                          label: 'Start Protection',
                          icon: Icons.refresh_rounded,
                          onPressed: _initPermissions,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: SakSpace.xl),

              // What the AI is hearing, with the trigger line drawn in.
              Reveal(
                index: 2,
                child: SakGroup(
                  header: 'Listening',
                  children: [
                    SakRow(
                      icon: isDistressDetected
                          ? Icons.warning_amber_rounded
                          : (isAiActive ? Icons.hearing_rounded : Icons.psychology_alt_rounded),
                      iconColor: isDistressDetected ? c.danger : (isAiActive ? c.success : c.inkSecondary),
                      title: 'Hears: $currentAiPrediction',
                      titleStyle: context.type.bodyLarge?.copyWith(
                        fontWeight: isDistressDetected ? FontWeight.w600 : null,
                        color: isDistressDetected ? c.danger : null,
                      ),
                      subtitle: currentAiStatus,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.md, SakSpace.lg, SakSpace.lg),
                      child: ThresholdMeter(
                        value: currentAiConfidence,
                        threshold: YamnetDetector.threshold,
                      ),
                    ),
                    // Until the redesign's settings screen.
                    ValueListenableBuilder<bool>(
                      valueListenable: ProtectionService.enabled,
                      builder: (context, on, _) => SakRow(
                        icon: Icons.lock_clock_rounded,
                        iconColor: on ? c.success : c.inkSecondary,
                        title: 'Background protection',
                        subtitle: on
                            ? 'Keeps listening when the phone is locked'
                            : 'Listens only while Sakshya is open',
                        chevron: false,
                        trailing: Switch(value: on, onChanged: ProtectionService.setEnabled),
                        onTap: () => ProtectionService.setEnabled(!on),
                      ),
                    ),
                  ],
                ),
              ),

              if (isReady) ...[
                // Debug-only affordances: a stray tap on these in the field
                // could fire a false emergency upload, and they advertise
                // exactly how the app works to anyone holding the phone, so
                // they must never ship in a release build.
                if (kDebugMode)
                  Reveal(
                    index: 3,
                    child: SakGroup(
                      header: 'Debug',
                      children: [
                        SakRow(
                          icon: Icons.warning_amber_rounded,
                          iconColor: c.warning,
                          title: 'Simulate AI Distress',
                          chevron: false,
                          enabled: !(_isProcessingSave || isRecordingActive),
                          onTap: _isProcessingSave || isRecordingActive
                              ? null
                              : () async {
                                  logger.w("Demo AI distress trigger pressed.");
                                  await EmergencyController.simulateAIDistressDetection();
                                },
                        ),
                        SakRow(
                          icon: Icons.storage_rounded,
                          iconColor: c.inkSecondary,
                          title: 'Print Vault Contents',
                          chevron: false,
                          onTap: _debugPrintVault,
                        ),
                        // Until the redesign's settings screen: switch the launcher
                        // face. The calculator appears the next time the app opens.
                        ValueListenableBuilder<bool>(
                          valueListenable: DisguiseService.enabled,
                          builder: (context, disguised, _) => SakRow(
                            icon: Icons.calculate_rounded,
                            iconColor: c.inkSecondary,
                            title: disguised ? 'Stop Calculator Disguise' : 'Disguise as Calculator',
                            chevron: false,
                            onTap: () => DisguiseService.setEnabled(!disguised),
                          ),
                        ),
                      ],
                    ),
                  ),

                Reveal(
                  index: 4,
                  child: SakGroup(
                    header: 'Guardians',
                    children: [
                      SakRow(
                        icon: Icons.qr_code_2_rounded,
                        title: 'Show My QR',
                        subtitle: 'A guardian scans this to pair with you',
                        onTap: () => _push(const GuardianPairingScreen()),
                      ),
                      SakRow(
                        icon: Icons.qr_code_scanner_rounded,
                        title: 'Scan QR',
                        subtitle: 'Add someone you trust as a guardian',
                        onTap: () => _openCameraScreen(const GuardianScannerScreen()),
                      ),
                      SakRow(
                        icon: Icons.groups_rounded,
                        title: 'My Guardians',
                        onTap: () => _push(const GuardiansScreen()),
                      ),
                    ],
                  ),
                ),
                Reveal(
                  index: 5,
                  child: SakGroup(
                    header: 'Evidence',
                    children: [
                      SakRow(
                        icon: Icons.video_library_rounded,
                        title: 'My Evidence',
                        subtitle: 'Your sealed recordings',
                        onTap: () => _push(const EvidenceViewerScreen()),
                      ),
                      SakRow(
                        icon: Icons.shield_rounded,
                        title: 'Guardian Evidence',
                        subtitle: 'Clips from people who chose you',
                        onTap: () => _push(const GuardianEvidenceScreen()),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
