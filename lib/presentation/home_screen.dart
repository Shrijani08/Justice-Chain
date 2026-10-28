import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/app_services.dart';
import '../core/emergency_controller.dart';
import '../core/evidence_vault_service.dart';
import '../core/guardian_evidence_service.dart';
import '../core/identity_service.dart';
import '../core/mesh_service.dart';
import '../core/protection_service.dart';
import '../logic/guardian_manager.dart';
import '../logic/safety_signals.dart';
import 'add_guardian_screen.dart';
import 'design/components.dart';
import 'design/sentinel.dart';
import 'design/tokens.dart';
import 'evidence_viewer_screen.dart';
import 'guardian_evidence_screen.dart';
import 'guardians_screen.dart';
import 'guide_screens.dart';
import 'listening_screen.dart';
import 'profile_screen.dart';
import 'recording_screen.dart';
import 'setup_screens.dart';

/// What screens above home can ask of it: the home screen owns the camera
/// and the recording, so they go through here.
abstract final class SafetyActions {
  static _MainSafetyScreenState? _home;

  static Future<void> startRecording() async => _home?.startEmergencyRecording();

  static Future<void> stopRecording() async => _home?.stopEmergencyRecording();

  static bool get isSaving => _home?._isProcessingSave ?? false;

  /// Opens a screen that needs the camera itself (the QR scanner): home
  /// lets the camera go first and takes it back after.
  static Future<void> openCameraScreen(BuildContext context, Widget screen) async {
    final home = _home;
    if (home == null) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
      return;
    }
    await home._openCameraScreen(context, screen);
  }

  /// Opens Add guardian on its scan or show-my-QR tab.
  static Future<void> addGuardian(BuildContext context, {bool showMine = false}) =>
      openCameraScreen(context, AddGuardianScreen(showMine: showMine));
}

class MainSafetyScreen extends StatefulWidget {
  const MainSafetyScreen({super.key});

  @override
  State<MainSafetyScreen> createState() => _MainSafetyScreenState();
}

class _MainSafetyScreenState extends State<MainSafetyScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isProcessingSave = false;
  EffectCleanup? _cameraEffectCleanup;
  bool _cameraPermitted = false;
  bool _cameraLent = false; // another screen (the QR scanner) is using it
  bool _cameraSyncing = false;
  bool _cameraResync = false;
  bool _meshOn = false;
  bool _recordingRouteOpen = false;
  String _name = '';
  EffectCleanup? _distressEffectCleanup;
  EffectCleanup? _recordingRouteCleanup;

  @override
  void initState() {
    super.initState();
    SafetyActions._home = this;
    WidgetsBinding.instance.addObserver(this);
    _initPermissions();
    _setupAutomaticTrigger();
    IdentityService.getMyName().then((name) {
      if (mounted) setState(() => _name = name);
    });
    // When a recording ends, take the camera back or let it go to match the screen.
    _cameraEffectCleanup = effect(() {
      if (!isRecording.value) unawaited(_syncCamera());
    });
    // Any recording, however it started, shows the recording screen.
    _recordingRouteCleanup = effect(() {
      if (isRecording.value && !_recordingRouteOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openRecordingScreen());
      }
    });
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
    if (SafetyActions._home == this) SafetyActions._home = null;
    WidgetsBinding.instance.removeObserver(this);
    _cameraEffectCleanup?.call();
    _distressEffectCleanup?.call();
    _recordingRouteCleanup?.call();
    unawaited(EmergencyController.shutdownMonitoring());
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _openRecordingScreen() async {
    if (!mounted || _recordingRouteOpen || !isRecording.value) return;
    _recordingRouteOpen = true;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: SakMotion.of(context, const Duration(milliseconds: 380)),
        reverseTransitionDuration: SakMotion.of(context, SakMotion.standard),
        pageBuilder: (_, _, _) => RecordingScreen(startedAt: DateTime.now()),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
    _recordingRouteOpen = false;
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
    if (mounted) setState(() => _meshOn = canUseMesh);

    final hasCameraPermission = statuses[Permission.camera]?.isGranted ?? false;
    final hasMicrophonePermission =
        statuses[Permission.microphone]?.isGranted ?? false;

    if (hasMicrophonePermission) {
      logger.i("Microphone Permission Granted.");
      await EmergencyController.startBackgroundMonitoring();
      unawaited(_askBatteryExemptionOnce());
    }

    _cameraPermitted = hasCameraPermission && hasMicrophonePermission;
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
  Future<void> _openCameraScreen(BuildContext from, Widget screen) async {
    if (isRecording.value) {
      ScaffoldMessenger.of(from).showSnackBar(
        const SnackBar(content: Text('Stop the recording first.')),
      );
      return;
    }
    final navigator = Navigator.of(from);
    _cameraLent = true;
    await _releaseCamera();
    if (!mounted) {
      _cameraLent = false;
      return;
    }
    await navigator.push(MaterialPageRoute(builder: (context) => screen));
    _cameraLent = false;
    if (mounted) await _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => unawaited(_syncCamera());

  /// Vivo's and Samsung's battery savers stop background apps, so this asks
  /// Android once to leave Sakshya alone (step 6b). Setup asks first; the
  /// guide has the makers' own settings.
  Future<void> _askBatteryExemptionOnce() async {
    final box = Hive.box('vault_box');
    if (!ProtectionService.enabled.value || box.get(SetupFlow.batteryAskedKey) == true) return;
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    await box.put(SetupFlow.batteryAskedKey, true);
    await Permission.ignoreBatteryOptimizations.request();
  }

  /// The home screen holds the camera only while the app is on screen, so
  /// the background recorder can use it otherwise (step 6b). A recording
  /// already running with it finishes first; this runs again when it ends.
  Future<void> _syncCamera() async {
    if (_cameraSyncing) {
      _cameraResync = true;
      return;
    }
    _cameraSyncing = true;
    try {
      do {
        _cameraResync = false;
        if (isRecording.value || _cameraLent || !mounted) break;
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == AppLifecycleState.resumed) {
          if (_cameraController == null && _cameraPermitted) await _initializeCamera();
        } else if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          if (_cameraController != null) await _releaseCamera();
        }
      } while (_cameraResync);
    } finally {
      _cameraSyncing = false;
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

  /// Manual "Stop & seal" path. The automatic 45-second timeout path runs
  /// independently through EmergencyController and EvidenceVaultService,
  /// with no dependency on this screen being mounted.
  Future<void> stopEmergencyRecording() async {
    if (EmergencyController.isBackgroundRecording) {
      // Started while the app was away; the controller seals it.
      await EmergencyController.stopRecording();
      return;
    }
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

  void _push(Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final isReady = cameraReady.watch(context);
    final isAiActive = aiActive.watch(context);
    final isAiReady = aiModelReady.watch(context);
    final level = aiConfidence.watch(context);

    final (pillLabel, pillColor, headline, subline) = !isAiReady
        ? ('Starting', Ember.attention, 'Getting ready…', 'Loading the listening model on this phone.')
        : isAiActive && isReady
            ? ('Listening', Ember.sealed, "You're protected.", 'If it hears distress, recording starts on its own.')
            : isAiActive
                ? ('Listening', Ember.sealed, "You're protected.", 'Listening. Allow the camera to record video too.')
                : ('Paused', Ember.attention, 'Not listening.', 'Allow the microphone so Sakshya can hear danger.');

    return Scaffold(
      backgroundColor: Ember.home,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const EmberBackground(
            color: Ember.home,
            glows: [
              Glow(color: Ember.deepWine, width: 420, height: 420, opacity: 0.75, left: -140, top: -160),
              Glow(color: Color(0xFF4A1430), width: 300, height: 300, opacity: 0.45, right: -140, top: 160),
              Glow(color: Ember.nightPlum, width: 360, height: 260, left: -60, bottom: -140),
            ],
          ),
          SafeArea(
            child: ValueListenableBuilder(
              valueListenable: Hive.box('vault_box').listenable(),
              builder: (context, _, _) => ValueListenableBuilder(
                valueListenable: Hive.box(MeshService.receivedSharesBoxName).listenable(),
                builder: (context, _, _) {
                  final guardianCount = GuardianManager.getTrustedGuardians().length;
                  final evidenceCount = Hive.box('vault_box')
                      .values
                      .where((v) => v is Map && v['status'] != null)
                      .length;
                  final incidents = GuardianEvidenceService.listIncidents();
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            _ProfilePill(name: _name, onTap: () => _push(const ProfileScreen())),
                            const Spacer(),
                            CircleButton(icon: Icons.help_outline_rounded, label: 'User guide', onTap: () => _push(const GuideScreen())),
                            const SizedBox(width: 8),
                            CircleButton(
                              icon: Icons.notifications_none_rounded,
                              label: 'Guardian alerts',
                              badge: incidents.any((i) => i.hasQuorum),
                              onTap: () => _push(const GuardianEvidenceScreen()),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Reveal(
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        PulseDot(color: pillColor),
                                        const SizedBox(width: 6),
                                        Text(pillLabel, style: TextStyle(fontFamily: SakFont.body, fontSize: 13, fontWeight: FontWeight.w600, color: pillColor)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(headline, style: context.type.displayMedium),
                                    const SizedBox(height: 8),
                                    Text(subline, style: context.type.bodySmall?.copyWith(fontSize: 14, height: 20 / 14)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 18),
                              Semantics(
                                button: true,
                                label: 'Open listening',
                                child: GestureDetector(
                                  onTap: () => _push(const ListeningScreen()),
                                  // Narrow phones give the headline the room.
                                  child: SakOrb(size: MediaQuery.sizeOf(context).width < 380 ? 118 : 150, level: level),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Reveal(
                          index: 1,
                          child: _SosPill(
                            ready: isReady,
                            onTap: isReady ? startEmergencyRecording : _initPermissions,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Reveal(
                          index: 2,
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _Tile(
                                      count: '$guardianCount',
                                      label: 'Guardians',
                                      colors: const [Color(0xFF7A2E40), Color(0xFF3A1320), Color(0xFF0E0809)],
                                      onTap: () => _push(const GuardiansScreen()),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _Tile(
                                      count: '$evidenceCount',
                                      label: 'My evidence',
                                      colors: const [Color(0xFF4E2A5E), Color(0xFF24132E), Color(0xFF0C080E)],
                                      onTap: () => _push(const EvidenceViewerScreen()),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _Tile(
                                      icon: Icons.qr_code_2_rounded,
                                      label: 'Add guardian',
                                      colors: const [Color(0xFF6E3A30), Color(0xFF33181A), Color(0xFF0E0909)],
                                      onTap: () => SafetyActions.addGuardian(context),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _Tile(
                                      count: '${incidents.length}',
                                      label: 'Guardian evidence',
                                      colors: const [Color(0xFF3C3F58), Color(0xFF1C1D2A), Color(0xFF0A0A0E)],
                                      onTap: () => _push(const GuardianEvidenceScreen()),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Reveal(
                          index: 3,
                          child: _ReadinessBar(
                            camera: isReady,
                            listening: isAiActive,
                            model: isAiReady,
                            mesh: _meshOn,
                            onFix: () => _push(const GuideBackgroundScreen()),
                          ),
                        ),
                        const Reveal(index: 4, child: _SetupCard()),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfilePill extends StatelessWidget {
  const _ProfilePill({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Profile, $name',
      child: Pressable(
        child: GestureDetector(
          onTap: onTap,
          child: Glass(
            radius: SakRadius.pill,
            padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFF8A5B), Color(0xFFC2185B), Color(0xFF5A1424)],
                        stops: [0, 0.6, 1],
                      ),
                    ),
                    child: Text(
                      name.isEmpty ? '' : name.characters.first.toUpperCase(),
                      style: const TextStyle(fontFamily: SakFont.body, fontWeight: FontWeight.w700, fontSize: 15, color: Ember.ink),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: SakFont.body, fontWeight: FontWeight.w600, fontSize: 15, height: 1.15, color: Ember.ink)),
                        const Text('Profile', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, height: 1.15, color: Ember.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The manual SOS path: it calls startEmergencyRecording() directly,
/// bypassing the AI model and its 2-of-3 confirmation window entirely. A
/// victim who can act must never depend on the model being right.
class _SosPill extends StatelessWidget {
  const _SosPill({required this.ready, required this.onTap});
  final bool ready;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: ready ? 'SOS, start recording' : 'Recording is not ready. Allow camera and microphone',
      child: Pressable(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Ember.emberStart, Ember.emberEnd], stops: [0, 0.75]),
              borderRadius: BorderRadius.circular(SakRadius.pill),
              border: Border.all(color: Ember.emberEdge),
              boxShadow: const [BoxShadow(color: Color(0x8C5A0F22), blurRadius: 36, offset: Offset(0, 16))],
            ),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x2EFFFFFF)),
                    child: Icon(ready ? Icons.videocam_outlined : Icons.videocam_off_outlined, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ready ? 'SOS · Start recording' : 'Recording is not ready',
                          style: const TextStyle(fontFamily: SakFont.body, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: Colors.white),
                        ),
                        Text(
                          ready ? 'One tap. No AI needed.' : 'Tap to allow the camera and microphone',
                          style: const TextStyle(fontFamily: SakFont.body, fontSize: 13, color: Color(0xD9FFFFFF)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.colors, required this.onTap, this.count, this.icon});

  final String label;
  final List<Color> colors;
  final VoidCallback onTap;
  final String? count;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: count == null ? label : '$label, $count',
      child: Pressable(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 132,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SakRadius.card),
              border: Border.all(color: const Color(0x1AFFFFFF)),
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors, stops: const [0, 0.52, 1]),
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (count != null)
                    Text(count!, style: const TextStyle(fontFamily: SakFont.display, fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: Ember.ink, height: 1.1))
                  else
                    Padding(padding: const EdgeInsets.only(bottom: 6), child: Icon(icon, size: 26, color: Ember.ink)),
                  const SizedBox(height: 2),
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(fontFamily: SakFont.mono, fontSize: 11, letterSpacing: 1.4, color: Color(0xD9FFFFFF)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Finish setup · 4 of 6 done" until everything on the setup list is
/// done; then it disappears.
class _SetupCard extends StatefulWidget {
  const _SetupCard();

  @override
  State<_SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<_SetupCard> with WidgetsBindingObserver {
  ({int done, int total})? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final progress = SafetySetup.progress(await SafetySetup.check());
    if (mounted) setState(() => _progress = progress);
  }

  Future<void> _open() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const GuideBackgroundScreen.setup()));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    if (progress == null || progress.done == progress.total) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        button: true,
        label: 'Finish setup, ${progress.done} of ${progress.total} done',
        child: Pressable(
          child: GestureDetector(
            onTap: _open,
            child: Glass(
              radius: 20,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.checklist_rounded, size: 20, color: Ember.attention),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Finish setup', style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 19 / 14))),
                  Text(
                    '${progress.done} of ${progress.total} done',
                    style: const TextStyle(fontFamily: SakFont.body, fontSize: 12, fontWeight: FontWeight.w700, color: Ember.attention),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 20, color: Ember.ink2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadinessBar extends StatelessWidget {
  const _ReadinessBar({required this.camera, required this.listening, required this.model, required this.mesh, required this.onFix});

  final bool camera;
  final bool listening;
  final bool model;
  final bool mesh;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final allReady = camera && listening && model;
    final missing = [
      if (!camera) 'camera',
      if (!listening) 'microphone',
      if (!model) 'AI model',
    ];
    final text = allReady ? 'Camera, mic and AI model ready' : 'Not ready: ${missing.join(', ')}';
    return Semantics(
      button: !allReady,
      child: GestureDetector(
        onTap: allReady ? null : onFix,
        child: Glass(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(allReady ? Icons.verified_user_outlined : Icons.warning_amber_rounded, size: 20, color: allReady ? Ember.sealed : Ember.attention),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 19 / 14))),
              Text(
                allReady ? (mesh ? 'Offline relay on' : 'Offline relay off') : 'Fix',
                style: TextStyle(
                  fontFamily: SakFont.body,
                  fontSize: 12,
                  fontWeight: allReady ? FontWeight.w400 : FontWeight.w700,
                  color: allReady ? Ember.ink2 : Ember.attention,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
