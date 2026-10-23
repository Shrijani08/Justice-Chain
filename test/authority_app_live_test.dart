import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
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
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/core/shamir.dart';
import 'package:justice_chain/logic/guardian_manager.dart';

// Step 8d against the live gateway, driven by the app's own services rather
// than hand-built requests: a guardian phone and a victim phone register
// (AuthorityService), the victim names the guardian (GuardianManager +
// syncGuardians), opts in, records, and the anchor hook plus the outbox give
// SimPolice its piece. Writes build/authority_live_share.json for the
// officer-side check, fabric/network/check-authority-share.sh.
//
// Each run registers two test phones and anchors one test clip (permanent).
//   FABRIC_GATEWAY_URL=http://localhost:8800 flutter test test/authority_app_live_test.dart

/// Forwards to the real gateway and keeps the bodies the app posts.
class _RecordingClient extends http.BaseClient {
  final _inner = http.Client();
  final posted = <String, Map<String, dynamic>>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.method == 'POST') {
      posted[request.url.path] = jsonDecode(request.body) as Map<String, dynamic>;
    }
    return _inner.send(request);
  }
}

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<Map<String, dynamic>> _becomeNewPhone() async {
  FlutterSecureStorage.setMockInitialValues({});
  IdentityService.resetCacheForTest();
  await IdentityService.initializeDevice();
  return jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // talk to the real gateway
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];
  final gatewayKey = {'X-Api-Key': Platform.environment['FABRIC_GATEWAY_API_KEY'] ?? ''};

  test(
    'live: the app registers, syncs its guardian and shares a piece with SimPolice',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('authority_live');
      Hive.init(tempDir.path);
      final vault = await Hive.openBox('vault_box');
      await Hive.openBox(OutboxService.boxName);
      OutboxService.manageAdvertising = false;
      final client = _RecordingClient();
      final gateway = FabricLedgerService(gatewayUrl: gatewayUrl!, apiKey: Platform.environment['FABRIC_GATEWAY_API_KEY'], client: client);
      AuthorityService.gatewayForTest = gateway;
      AuthorityService.demoBuildForTest = true;
      AnchoringService.ledgerForTest = gateway;

      try {
        // The guardian's phone registers and keeps its key pair.
        final guardian = await _becomeNewPhone();
        await AuthorityService.registerThisPhone();
        final guardianKeys = await IdentityService.getX25519KeyPair();

        // The victim's phone: registers, pairs with the guardian, syncs.
        final victim = await _becomeNewPhone();
        final victimNode = victim['node_id'] as String;
        await GuardianManager.addGuardian(
          nodeId: guardian['node_id'] as String,
          publicKey: guardian['public_key'] as String,
          name: 'Live guardian',
          x25519PublicKey: guardian['x25519_public_key'] as String,
          anchoringAddress: guardian['anchoring_address'] as String,
        );
        await AuthorityService.syncGuardians();
        final onLedger = await gateway.getGuardians(victimNode);
        expect(onLedger['guardians'], [guardian['node_id']]);

        // Opt in, then record: the record is sealed the way the vault seals it.
        await AuthorityService.setShareWithAuthority(true);
        final dir = await Directory.systemTemp.createTemp('clip');
        final clip = File('${dir.path}/clip.mp4')
          ..writeAsBytesSync(utf8.encode('step 8d live ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}'));
        final sealed = await EvidenceEncryptor.encryptAndSeal(
          clip.path,
          guardians: [(nodeId: guardian['node_id'] as String, x25519PublicKeyB64: guardian['x25519_public_key'] as String)],
        );
        final key = sealed.plaintextHash;
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
          'cid': 'bafystep8dlivetest',
        });

        // The app's own anchoring path, then the outbox shares the piece.
        await EvidenceVaultService.anchorRecord(key);
        expect(Hive.box(OutboxService.boxName).keys, contains('${OutboxService.jobAuthorityShare}:$key'));
        await OutboxService.process();

        final record = vault.get(key) as Map;
        final share = record['authorityShare'] as Map;
        expect(share['msp'], 'SimPoliceMSP');
        expect(share['blockNumber'], greaterThan(0));
        final listed = await http.get(Uri.parse('$gatewayUrl/authority-shares/SimPoliceMSP'), headers: gatewayKey);
        expect((jsonDecode(listed.body) as List).map((c) => c['manifestHash']), contains(key));

        // The piece the app sealed, recomputed from the clip key (the vault's
        // own HKDF derivation), opens the clip with the guardian's piece.
        final x = record['authorityShareX'] as int;
        final incidentKey = await (await EvidenceEncryptor.unwrapIncidentKey(sealed.wrappedKeyB64)).extractBytes();
        final coefficients = await (await Hkdf(hmac: Hmac.sha256(), outputLength: incidentKey.length).deriveKey(
          secretKey: SecretKey(incidentKey),
          info: utf8.encode('justice-chain-shamir-coefficients-v1'),
        )).extractBytes();
        final policePiece = Shamir.shareAt(secret: Uint8List.fromList(incidentKey), coefficients: [Uint8List.fromList(coefficients)], x: x);
        final guardianPiece = await EvidenceEncryptor.unsealGuardianShare(
          sealedShareB64: (record['guardianShares'] as Map)[guardian['node_id']] as String,
          ownX25519KeyPair: guardianKeys,
          senderX25519PublicKeyB64: victim['x25519_public_key'] as String,
        );
        final plaintext = await EvidenceEncryptor.decryptFileWithShares(
          cipherPath: sealed.cipherPath,
          shares: [policePiece, guardianPiece],
          threshold: 2,
        );
        expect(_sha256Hex(plaintext), key);

        final sent = client.posted['/authority-shares']!;
        final out = File('build/authority_live_share.json');
        await out.parent.create(recursive: true);
        await out.writeAsString(jsonEncode({
          'manifestHash': key,
          'blockNumber': share['blockNumber'],
          'sealedShare': sent['sealedShare'],
          'x': x,
          'yHex': policePiece.y.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        }));
      } finally {
        AuthorityService.gatewayForTest = null;
        AuthorityService.demoBuildForTest = null;
        AnchoringService.ledgerForTest = null;
        OutboxService.manageAdvertising = true;
        await Hive.deleteFromDisk();
        await Hive.close();
      }
    },
    skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
