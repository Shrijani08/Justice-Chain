import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_services.dart';
import '../core/authority_service.dart';
import '../core/device_link_service.dart';
import '../core/disguise_service.dart';
import '../core/emergency_controller.dart';
import '../core/identity_service.dart';
import '../core/pinata_service.dart';
import '../core/protection_service.dart';
import '../logic/guardian_manager.dart';
import '../logic/safety_signals.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'evidence_viewer_screen.dart';
import 'guardians_screen.dart';
import 'guide_screens.dart';
import 'home_screen.dart';
import 'police_requests_screen.dart';
import 'setup_screens.dart';

/// The user, their guardians and evidence, privacy switches and the guide.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _name = '';
  String _nodeId = '';
  bool _codeWritten = true;
  late Future<int> _problems = BackgroundHealth.problems();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await IdentityService.getMyName();
    final id = await IdentityService.getMyNodeId();
    final pending = await IdentityService.pendingRecoveryCode();
    if (!mounted) return;
    setState(() {
      _name = name;
      _nodeId = id;
      _codeWritten = pending == null;
    });
  }

  static String _shortId(String id) {
    if (id.length < 8) return id.toUpperCase();
    return '${id.substring(0, 4)}·${id.substring(id.length - 4)}'.toUpperCase();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() => _problems = BackgroundHealth.problems());
  }

  /// Links an SOS device (scan its QR), or updates or unlinks the linked one.
  Future<void> _sosDevice() async {
    final device = DeviceLinkService.linkedDevice();
    if (device == null) {
      await SafetyActions.addGuardian(context);
      if (mounted) setState(() {});
      return;
    }
    final action = await showSakSheet<String>(
      context,
      (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('SOS device', style: sheetContext.type.headlineSmall),
          const SizedBox(height: 6),
          MonoText('Device ${device['nodeId']}', style: const TextStyle(fontSize: 12, color: Ember.ink2)),
          const SizedBox(height: 12),
          Text(
            'Send update gives the device your current guardians. The app also does this every time it starts.',
            style: sheetContext.type.bodyMedium?.copyWith(fontSize: 14, color: const Color(0xB3F4ECEE)),
          ),
          const SizedBox(height: 16),
          SakButton(label: 'Send update', style: SakButtonStyle.pearl, height: 54, fontSize: 16, onPressed: () => Navigator.pop(sheetContext, 'update')),
          const SizedBox(height: 10),
          SakButton(label: 'Unlink device', style: SakButtonStyle.glass, height: 54, fontSize: 16, onPressed: () => Navigator.pop(sheetContext, 'unlink')),
        ],
      ),
    );
    if (!mounted || action == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (action == 'unlink') {
      await DeviceLinkService.unlink();
      messenger.showSnackBar(const SnackBar(content: Text('SOS device unlinked on this phone.')));
    } else {
      try {
        await DeviceLinkService.sendSetup();
        messenger.showSnackBar(const SnackBar(content: Text('Update sent. The device picks it up within a few minutes.')));
      } catch (e) {
        messenger.showSnackBar(const SnackBar(content: Text('Could not reach the server. Check your internet and try again.')));
      }
    }
    if (mounted) setState(() {});
  }

  /// Turning the disguise on while listening also walks the user through
  /// hiding the notification's name: Android heads every notification with
  /// the app's real name, and only the user can turn its channel off.
  Future<void> _setDisguise(bool on) async {
    await DisguiseService.setEnabled(on);
    if (!on || !ProtectionService.enabled.value || !ProtectionService.listenWhileDisguised.value) return;
    if (!await ProtectionService.disguisedNotificationVisible() || !mounted) return;
    await _open(const HideNotificationScreen(fromGuide: true));
  }

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF6A1A2E), width: 420, height: 340, opacity: 0.85, left: -15, top: -120),
        Glow(color: Color(0xFFFF8A5B), width: 220, height: 220, opacity: 0.18, right: -60, top: 140),
      ],
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          const SakTopBar(title: 'Profile'),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: Hive.box('vault_box').listenable(),
              builder: (context, box, _) {
                final guardians = GuardianManager.getTrustedGuardians().length;
                final evidence = box.values.where((v) => v is Map && v['status'] != null).length;
                return ListView(
                  padding: const EdgeInsets.only(top: 22, bottom: 28),
                  children: [
                    Reveal(child: _Identity(name: _name, nodeId: _shortId(_nodeId))),
                    const SizedBox(height: 22),
                    Reveal(
                      index: 1,
                      child: FutureBuilder<int>(
                        future: _problems,
                        builder: (context, snap) {
                          final n = snap.data ?? 0;
                          return SakGroup(children: [
                            SakRow(
                              icon: Icons.group_outlined,
                              iconColor: const Color(0xFFFF8FA3),
                              title: 'Guardians',
                              value: '$guardians',
                              onTap: () => _open(const GuardiansScreen()),
                            ),
                            SakRow(
                              icon: Icons.qr_code_2_rounded,
                              iconColor: const Color(0xFFFFB08F),
                              title: 'My QR code',
                              onTap: () => SafetyActions.addGuardian(context, showMine: true),
                            ),
                            if (AuthorityService.ledgerFeaturesEnabled)
                              SakRow(
                                icon: Icons.sos_outlined,
                                iconColor: const Color(0xFFFF8FA3),
                                title: 'SOS device',
                                value: DeviceLinkService.linkedDevice() == null ? 'Not linked' : 'Linked',
                                onTap: _sosDevice,
                              ),
                            SakRow(
                              icon: Icons.videocam_outlined,
                              iconColor: const Color(0xFFC9A2F2),
                              title: 'My evidence',
                              value: '$evidence',
                              onTap: () => _open(const EvidenceViewerScreen()),
                            ),
                            if (AuthorityService.demoBuild)
                              SakRow(
                                icon: Icons.local_police_outlined,
                                iconColor: Ember.rose,
                                title: 'Police requests',
                                onTap: () => _open(const PoliceRequestsScreen()),
                              ),
                            SakRow(
                              icon: Icons.menu_book_outlined,
                              iconColor: Ember.attention,
                              title: 'User guide',
                              trailing: n > 0 ? StatusPill(label: '$n to fix', color: Ember.attention) : null,
                              onTap: () => _open(const GuideScreen()),
                            ),
                          ]);
                        },
                      ),
                    ),
                    const SizedBox(height: 18),
                    Reveal(
                      index: 2,
                      child: SakGroup(header: 'Privacy', children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: DisguiseService.enabled,
                          builder: (context, on, _) => SakRow(
                            icon: Icons.calculate_outlined,
                            title: 'Calculator disguise',
                            subtitle: 'Opens as a calculator. PIN + = unlocks, 112 = records.',
                            chevron: false,
                            trailing: SakSwitch(value: on, onChanged: _setDisguise),
                            onTap: () => _setDisguise(!on),
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: ProtectionService.listenWhileDisguised,
                          builder: (context, on, _) => SakRow(
                            icon: Icons.hearing_outlined,
                            title: 'Listen while disguised',
                            subtitle: on
                                ? 'Android shows a microphone dot under the calculator'
                                : 'Under the calculator only “112 =” records',
                            chevron: false,
                            trailing: SakSwitch(value: on, onChanged: ProtectionService.setListenWhileDisguised),
                            onTap: () => ProtectionService.setListenWhileDisguised(!on),
                          ),
                        ),
                        SakRow(
                          icon: Icons.key_rounded,
                          iconColor: Ember.blush,
                          title: 'Recovery code',
                          chevron: false,
                          trailing: Text(
                            _codeWritten ? 'Written down' : 'Not confirmed',
                            style: TextStyle(fontFamily: SakFont.body, fontSize: 13, color: _codeWritten ? Ember.ink2 : Ember.attention),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 18),
                    Reveal(
                      index: 3,
                      child: SakGroup(header: 'Protection', children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: ProtectionService.enabled,
                          builder: (context, on, _) => SakRow(
                            icon: Icons.shield_outlined,
                            iconColor: on ? Ember.sealed : Ember.ink,
                            title: 'Background protection',
                            subtitle: on ? 'Keeps listening when the phone is locked' : 'Listens only while Sakshya is open',
                            chevron: false,
                            trailing: SakSwitch(value: on, onChanged: ProtectionService.setEnabled),
                            onTap: () => ProtectionService.setEnabled(!on),
                          ),
                        ),
                        SakRow(
                          icon: Icons.battery_5_bar_rounded,
                          title: 'Keep it running',
                          subtitle: 'Check permissions, battery and the notification',
                          onTap: () => _open(const GuideBackgroundScreen()),
                        ),
                      ]),
                    ),
                    // Debug-only: a stray tap on these in the field could fire
                    // a false emergency upload, and they advertise how the app
                    // works, so they never ship in a release build.
                    if (kDebugMode) ...[
                      const SizedBox(height: 18),
                      const _DebugTools(),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      "Sakshya · keys stay in this phone's hardware keystore",
                      textAlign: TextAlign.center,
                      style: context.type.labelSmall?.copyWith(color: Ember.ink3),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.name, required this.nodeId});
  final String name;
  final String nodeId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              startAngle: 3.49,
              endAngle: 3.49 + 6.2832,
              colors: [Color(0xFFFF8A5B), Color(0xFFFF4D6D), Color(0xFF8E2DE2), Color(0xFFFF8A5B)],
            ),
          ),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3A1520), Color(0xFF1A0B10)]),
              border: Border.all(color: Ember.ground, width: 3),
            ),
            child: Text(
              name.isEmpty ? '' : name.characters.first.toUpperCase(),
              style: const TextStyle(fontFamily: SakFont.display, fontSize: 38, fontWeight: FontWeight.w700, color: Ember.ink),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(name, style: context.type.headlineMedium),
        const SizedBox(height: 10),
        Glass(
          radius: SakRadius.pill,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Node ID', style: context.type.labelSmall),
              const SizedBox(width: 8),
              MonoText(nodeId, style: const TextStyle(letterSpacing: 0.6)),
            ],
          ),
        ),
      ],
    );
  }
}

class _DebugTools extends StatelessWidget {
  const _DebugTools();

  void _printVault() {
    final entries = Hive.box('vault_box').toMap();
    logger.i("=== MANUAL VAULT CHECK (${entries.length} items) ===");
    entries.forEach((key, data) {
      // Evidence records carry a 'status' field; other box entries (the
      // trusted-guardians map) are skipped rather than misreported.
      if (data is Map && data['status'] != null) {
        final fullHash = (data['hash'] ?? key).toString();
        final displayHash = fullHash.length > 15 ? fullHash.substring(0, 15) : fullHash;
        logger.d("Key $key: Hash: $displayHash... | CID: ${data['cid'] ?? 'Pending/None'} | Path: ${data['path']}");
      }
    });
  }

  // An unauthenticated upload trigger with no relation to the emergency
  // flow: debug builds only.
  Future<void> _testPinata(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/test_evidence.txt');
      await file.writeAsString('This is a test distress signal for Justice-Chain. The vault is secure!');
      final cid = await PinataService.uploadToIPFS(file.path);
      messenger.showSnackBar(SnackBar(content: Text('Uploaded: $cid')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SakGroup(header: 'Debug', children: [
      SakRow(
        icon: Icons.warning_amber_rounded,
        iconColor: Ember.attention,
        title: 'Simulate AI distress',
        chevron: false,
        onTap: () {
          if (isRecording.value) return;
          logger.w("Demo AI distress trigger pressed.");
          EmergencyController.simulateAIDistressDetection();
          Navigator.popUntil(context, (r) => r.isFirst);
        },
      ),
      SakRow(icon: Icons.storage_rounded, title: 'Print vault contents', chevron: false, onTap: _printVault),
      SakRow(icon: Icons.cloud_upload_outlined, title: 'Test IPFS upload', chevron: false, onTap: () => _testPinata(context)),
    ]);
  }
}
