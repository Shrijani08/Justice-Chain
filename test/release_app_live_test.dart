import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/logic/guardian_manager.dart';

// Step 9c against the live network, with the officer working through the
// real portal: the victim shares two clips with SimPolice, the officer
// requests access to each, a guardian approves the first and the victim the
// second (both through the app's AuthorityService and outbox), and the
// portal then opens each clip, passing every check, byte for byte.
//
// Needs the gateway (8800), the portal (8900) started with
// IPFS_GATEWAY=http://127.0.0.1:8901/, and a static server on 8901 serving
// build/portal_ipfs, where this test puts the ciphertext. Each run registers
// two test phones and anchors two test clips (permanent).
//   FABRIC_GATEWAY_URL=http://localhost:8800 PORTAL_URL=http://localhost:8900 \
//     flutter test test/release_app_live_test.dart

Future<Map<String, String>> _becomeNewPhone() async {
  FlutterSecureStorage.setMockInitialValues({});
  IdentityService.resetCacheForTest();
  await IdentityService.initializeDevice();
  return const FlutterSecureStorage().readAll();
}

/// Switches the test to a phone made earlier by [_becomeNewPhone].
void _becomePhone(Map<String, String> storage) {
  FlutterSecureStorage.setMockInitialValues(Map.of(storage));
  IdentityService.resetCacheForTest();
}

Future<Map<String, dynamic>> _qr() async => jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;

Future<void> _drainOutbox() async {
  final outbox = Hive.box(OutboxService.boxName);
  for (var i = 0; i < 600 && outbox.isNotEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  expect(outbox.toMap(), isEmpty, reason: 'every queued job finished');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // talk to the real gateway and portal
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];
  final portalUrl = Platform.environment['PORTAL_URL'] ?? 'http://localhost:8900';

  Future<Map<String, dynamic>> portalPost(String path, [Map<String, Object?> body = const {}]) async {
    final response = await http.post(
      Uri.parse('$portalUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    expect(response.statusCode, 200, reason: '$path: ${response.body}');
    return decoded;
  }

  /// The officer opens the clip; every check passes and the video is the original.
  Future<void> expectPortalOpens(String hash, List<int> original) async {
    final opened = await portalPost('/api/clips/$hash/open');
    final checks = List<Map<String, dynamic>>.from(opened['checks'] as List);
    for (final c in checks) {
      expect(c['ok'], isTrue, reason: '${c['name']}: ${c['detail']}');
    }
    expect(checks.map((c) => c['name']), contains('Hash matches the ledger record'));
    final video = await http.get(Uri.parse('$portalUrl${opened['videoUrl']}'));
    expect(video.bodyBytes, original);

    // The supervisor's view of the chain of custody shows every step.
    final audit = await http.get(Uri.parse('$portalUrl/api/clips/$hash/audit'));
    expect(audit.statusCode, 200, reason: audit.body);
    final events = [for (final e in jsonDecode(audit.body) as List) e['event']];
    expect(events, ['shared', 'requested', 'released', 'opened']);
  }

  test(
    'live: a guardian and the victim each approve an officer\'s request, and the portal opens the clip',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('release_live');
      Hive.init(tempDir.path);
      final vault = await Hive.openBox('vault_box');
      await Hive.openBox(OutboxService.boxName);
      final received = await Hive.openBox(MeshService.receivedSharesBoxName);
      OutboxService.manageAdvertising = false;
      final gateway = FabricLedgerService(gatewayUrl: gatewayUrl!, apiKey: Platform.environment['FABRIC_GATEWAY_API_KEY']);
      AuthorityService.gatewayForTest = gateway;
      AuthorityService.demoBuildForTest = true;
      AnchoringService.ledgerForTest = gateway;

      try {
        final guardianPhone = await _becomeNewPhone();
        final guardian = await _qr();
        await AuthorityService.registerThisPhone();

        final victimPhone = await _becomeNewPhone();
        final victim = await _qr();
        final victimNode = victim['node_id'] as String;
        await AuthorityService.registerThisPhone();
        await GuardianManager.addGuardian(
          nodeId: guardian['node_id'] as String,
          publicKey: guardian['public_key'] as String,
          name: 'Live guardian',
          x25519PublicKey: guardian['x25519_public_key'] as String,
          anchoringAddress: guardian['anchoring_address'] as String,
        );
        await _drainOutbox(); // adding a guardian queues the ledger sync
        expect((await gateway.getGuardians(victimNode))['guardians'], [guardian['node_id']]);
        await AuthorityService.setShareWithAuthority(true);

        /// Records, uploads (to the IPFS stand-in), anchors and shares a clip,
        /// the way the vault does. Returns its hash and plaintext.
        Future<(String, List<int>)> recordAndShare(String label) async {
          final dir = await Directory.systemTemp.createTemp('clip');
          final bytes = utf8.encode('step 9c live $label ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}');
          final clip = File('${dir.path}/clip.mp4')..writeAsBytesSync(bytes);
          final sealed = await EvidenceEncryptor.encryptAndSeal(
            clip.path,
            guardians: [(nodeId: guardian['node_id'] as String, x25519PublicKeyB64: guardian['x25519_public_key'] as String)],
          );
          final key = sealed.plaintextHash;
          final cid = 'bafy9clive${key.substring(0, 16)}';
          await File(sealed.cipherPath).copy('build/portal_ipfs/$cid');
          await vault.put(key, {
            'authorityMsp': AuthorityService.authorityForNewRecordings(),
            'path': sealed.cipherPath,
            'hash': key,
            'wrappedKey': sealed.wrappedKeyB64,
            'signature': sealed.signatureB64,
            'guardianShares': sealed.guardianShares,
            'nextShareX': sealed.nextShareX,
            'threshold': sealed.threshold,
            'timestamp': sealed.encryptedAt.toIso8601String(),
            'status': 'uploaded_to_ipfs',
            'cid': cid,
          });
          await EvidenceVaultService.anchorRecord(key);
          await OutboxService.process();
          expect((vault.get(key) as Map)['authorityShare'], isNotNull);
          return (key, bytes);
        }

        // Clip 1: the officer asks; the guardian approves with their own piece.
        final (first, firstBytes) = await recordAndShare('guardian');
        final firstRequest = await portalPost('/api/clips/$first/requests', {
          'reason': 'Live test: guardian approval',
          'caseRef': 'TEST-9C-1',
        });
        final firstId = firstRequest['requestId'] as String;
        final guardianPiece = (vault.get(first) as Map)['guardianShares'][guardian['node_id']] as String;

        _becomePhone(guardianPhone);
        await received.put('$first:$victimNode', {
          'manifestHash': first,
          'victimNodeId': victimNode,
          'senderX25519': victim['x25519_public_key'],
          'sealedShare': guardianPiece,
          'receivedAt': DateTime.now().toIso8601String(),
        });
        final asGuardian = await AuthorityService.openRequestsIGuard();
        expect(asGuardian.map((r) => r['requestId']), contains(firstId));
        await AuthorityService.approveRequest(firstId);
        await _drainOutbox();
        expect((await gateway.getAccessRequest(firstId))['status'], 'released');
        await expectPortalOpens(first, firstBytes);

        // Clip 2: the officer asks; the victim approves with a new piece.
        _becomePhone(victimPhone);
        final (second, secondBytes) = await recordAndShare('victim');
        final secondRequest = await portalPost('/api/clips/$second/requests', {
          'reason': 'Live test: victim approval',
          'caseRef': 'TEST-9C-2',
        });
        final secondId = secondRequest['requestId'] as String;
        final asVictim = await AuthorityService.openRequestsForMyRecordings();
        expect(asVictim.map((r) => r['requestId']), contains(secondId));
        expect(asVictim.map((r) => r['requestId']), isNot(contains(firstId)));
        await AuthorityService.approveRequest(secondId);
        await _drainOutbox();
        expect((await gateway.getAccessRequest(secondId))['status'], 'released');
        await expectPortalOpens(second, secondBytes);
      } finally {
        AuthorityService.gatewayForTest = null;
        AuthorityService.demoBuildForTest = null;
        AnchoringService.ledgerForTest = null;
        OutboxService.manageAdvertising = true;
        await Hive.deleteFromDisk();
        await Hive.close();
      }
    },
    skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway and portal' : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
