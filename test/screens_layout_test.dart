import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/logic/safety_signals.dart';
import 'package:justice_chain/presentation/design/app_theme.dart';
import 'package:justice_chain/presentation/evidence_viewer_screen.dart';
import 'package:justice_chain/presentation/guardian_evidence_screen.dart';
import 'package:justice_chain/presentation/guardians_screen.dart';
import 'package:justice_chain/presentation/guide_screens.dart';
import 'package:justice_chain/presentation/home_screen.dart';
import 'package:justice_chain/presentation/listening_screen.dart';
import 'package:justice_chain/presentation/police_requests_screen.dart';
import 'package:justice_chain/presentation/profile_screen.dart';
import 'package:justice_chain/presentation/recording_screen.dart';
import 'package:justice_chain/presentation/registration_screen.dart';
import 'package:justice_chain/presentation/restore_screen.dart';
import 'package:justice_chain/presentation/setup_screens.dart';

import 'helpers/app_fonts.dart';

/// Every redesigned screen, laid out at the canvas's phone and a small
/// one, with the real fonts. A layout overflow fails the test. Run with
/// --dart-define=SCREENSHOTS=true --update-goldens to also save PNGs under
/// build/screens for a visual check.
void main() {
  const shots = bool.fromEnvironment('SCREENSHOTS');
  late Directory tempDir;

  setUpAll(loadAppFonts);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sak_screens');
    Hive.init(tempDir.path);
    final vault = await Hive.openBox('vault_box');
    await Hive.openBox(MeshService.receivedSharesBoxName);
    await Hive.openBox(MeshService.relayBoxName);
    await Hive.openBox(OutboxService.boxName);
    FlutterSecureStorage.setMockInitialValues({'node_name': 'Asha', 'public_node_id': '7f3ac21e9b0d4a55'});

    final now = DateTime.now();
    await vault.put('trusted_guardians', {
      'aaaa1111bbbb2222': {'name': 'Mom', 'added_at': '2026-10-14T10:00:00', 'x25519_public_key': 'k1'},
      'c1d93333dddd7be0': {'name': 'Riya', 'added_at': '2026-10-15T10:00:00', 'x25519_public_key': 'k2'},
      'eeee5555ffff6666': {'name': 'Arjun', 'added_at': '2026-10-16T10:00:00'},
    });
    for (final (hash, status, ago) in [
      ('9f3a7c21e0b455d81a6fc3e90b7742d1', 'anchored', 0),
      ('41be0d93aaaa', 'uploaded_to_ipfs', 2),
      ('c07e55a2bbbb', 'locally_secured', 5),
    ]) {
      await vault.put(hash, {
        'hash': hash,
        'path': '/x/$hash',
        'wrappedKey': 'w',
        'status': status,
        'guardianShares': {'aaaa1111bbbb2222': 's', 'c1d93333dddd7be0': 's'},
        'timestamp': now.subtract(Duration(days: ago)).toIso8601String(),
        if (ago == 0) 'authorityMsp': AuthorityService.simPoliceMsp,
        if (ago == 0) 'authorityShare': {'msp': AuthorityService.simPoliceMsp, 'x': 3},
      });
    }

    // The simulated police: opted in, with one request for Asha's recording
    // and one for a recording of Mom's that Asha guards.
    await vault.put(AuthorityService.optInKey, AuthorityService.simPoliceMsp);
    await Hive.box(MeshService.receivedSharesBoxName).put('5be1:aaaa1111bbbb2222', {
      'manifestHash': '5be17d0c' * 8,
      'victimNodeId': 'aaaa1111bbbb2222',
      'capturedAt': now.subtract(const Duration(hours: 3)).toIso8601String(),
    });
    final asked = now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> request(String id, String victim, String hash) => {
          'requestId': id * 64,
          'manifestHash': hash,
          'authorityMsp': AuthorityService.simPoliceMsp,
          'victimNodeId': victim,
          'requestedBy': 'officer1',
          'reason': 'Complaint registered on 24 Oct; the recording is needed to identify the accused.',
          'caseRef': 'DPA/2026/0147',
          'status': 'open',
          'requestedAt': asked,
        };
    final requests = {
      '7f3ac21e9b0d4a55': [request('a', '7f3ac21e9b0d4a55', '9f3a7c21e0b455d81a6fc3e90b7742d1')],
      'aaaa1111bbbb2222': [request('b', 'aaaa1111bbbb2222', '5be17d0c' * 8)],
    };
    AuthorityService.gatewayForTest = FabricLedgerService(
      gatewayUrl: 'http://gw',
      client: MockClient((r) async => http.Response(jsonEncode(requests[r.url.pathSegments.last] ?? []), 200)),
    );

    // Permissions: all granted. Other platform channels answer nothing.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      return switch (call.method) {
        'checkPermissionStatus' => 1,
        'requestPermissions' => {for (final p in call.arguments as List) p: 1},
        _ => null,
      };
    });
    for (final name in ['in.sakshya/protection', 'in.sakshya/disguise', 'com.llfbandit.record/messages', 'plugins.flutter.io/camera']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  tearDown(() async {
    AuthorityService.gatewayForTest = null;
    await Hive.deleteFromDisk();
    await Hive.close();
    isRecording.value = false;
  });

  final screens = <String, Widget Function()>{
    'identity': () => const RegistrationScreen(),
    'restore': () => const RestoreScreen(),
    'permissions': () => const PermissionsScreen(),
    'background_notice': () => const BackgroundNoticeScreen(),
    'hide_notification': () => const HideNotificationScreen(),
    'battery': () => const BatteryScreen(),
    'listening': () => const ListeningScreen(),
    'sealed': () => SealedScreen(since: DateTime.now().subtract(const Duration(minutes: 1))),
    'profile': () => const ProfileScreen(),
    'guardians': () => const GuardiansScreen(),
    'police_requests': () => const PoliceRequestsScreen(),
    'evidence': () => const EvidenceViewerScreen(),
    'guardian_evidence': () => const GuardianEvidenceScreen(),
    'guide': () => const GuideScreen(),
    'guide_danger': () => const GuideTopicScreen(topic: GuideTopic.danger),
    'guide_lost_phone': () => const GuideTopicScreen(topic: GuideTopic.lostPhone),
    'guide_listening': () => const GuideTopicScreen(topic: GuideTopic.listening),
    'guide_background': () => const GuideBackgroundScreen(),
  };

  Future<void> show(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(theme: buildSakTheme(), debugShowCheckedModeBanner: false, home: screen));
    // Let futures resolve (Hive, mocked channels) and entrances finish.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final (sizeName, size) in const [('390x844', Size(390, 844)), ('360x640', Size(360, 640))]) {
    group(sizeName, () {
      for (final entry in screens.entries) {
        testWidgets(entry.key, (tester) async {
          tester.view.physicalSize = size * 3;
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await show(tester, entry.value());
          if (shots) {
            await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screens/$sizeName/${entry.key}.png'));
          }
        });
      }

      testWidgets('recording', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        isRecording.value = true;
        await show(tester, RecordingScreen(startedAt: DateTime.now().subtract(const Duration(seconds: 12))));
        if (shots) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screens/$sizeName/recording.png'));
        }
        // The clock counts up by itself (it once stayed on its first value).
        expect(find.text('00:12'), findsOneWidget);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('00:12'), findsNothing);
        isRecording.value = false;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        // The recording screen gives way to Sealed by itself.
        expect(find.text('Sealed.'), findsOneWidget);
      });

      testWidgets('home', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        // Home asks for everything at start; denying it keeps the camera,
        // AI and nearby plugins (absent in tests) from starting.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (call) async => switch (call.method) {
            'checkPermissionStatus' => 0,
            'requestPermissions' => {for (final p in call.arguments as List) p: 0},
            _ => null,
          },
        );
        aiModelReady.value = true;
        aiActive.value = true;
        cameraReady.value = true;
        addTearDown(() {
          aiModelReady.value = false;
          aiActive.value = false;
          cameraReady.value = false;
        });
        await show(tester, const MainSafetyScreen());
        expect(find.text("You're protected."), findsOneWidget);
        expect(find.text('SOS · Start recording'), findsOneWidget);
        if (shots) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screens/$sizeName/home.png'));
        }
        await tester.pumpWidget(const SizedBox());
      });
    });
  }
}
