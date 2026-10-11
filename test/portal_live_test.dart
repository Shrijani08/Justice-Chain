import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';

// Step 10 dry run without phones: the app's own recording pipeline feeds
// the officer portal through the live gateway.
//
//   JC_LIVE_PHASE=share    victim and guardian register; the victim encrypts
//                          a clip with encryptAndSeal (guardian gets piece 1),
//                          writes the ciphertext to build/portal_ipfs/<cid>
//                          (served in place of IPFS), anchors it and shares a
//                          late piece (issueGuardianShare) with SimPolice
//   (the officer requests access in the portal)
//   JC_LIVE_PHASE=release  the guardian unseals piece 1, re-seals it to
//                          SimPolice and releases it
//   (the officer opens the clip in the portal)
//
// State: build/portal_live_state.json (test keys only).
//   FABRIC_GATEWAY_URL=http://localhost:8800 JC_LIVE_PHASE=share flutter test test/portal_live_test.dart

final _stateFile = File('build/portal_live_state.json');
const _storage = FlutterSecureStorage();

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<String> _signAction(String payload) => AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload)));

void _becomePhone(Map<String, String> storage) {
  FlutterSecureStorage.setMockInitialValues(storage);
  IdentityService.resetCacheForTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding (needed for the secure-storage mock) fakes every HTTP call;
  // this test talks to the real gateway.
  HttpOverrides.global = null;
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];
  final phase = Platform.environment['JC_LIVE_PHASE'];

  Future<Map<String, dynamic>> post(String path, Object body) async {
    final response = await http.post(Uri.parse('$gatewayUrl$path'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError('POST $path -> ${response.statusCode}: ${decoded['error']}');
    }
    return decoded;
  }

  Future<dynamic> get(String path) async => jsonDecode((await http.get(Uri.parse('$gatewayUrl$path'))).body);

  Future<Map<String, String>> newRegisteredPhone() async {
    _becomePhone({});
    await IdentityService.initializeDevice();
    final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
    final address = (qr['anchoring_address'] as String).toLowerCase();
    final payload = 'justice-chain/register-node/v1|${qr['node_id']}|${qr['public_key']}|${qr['x25519_public_key']}|$address';
    await post('/nodes', {
      'nodeId': qr['node_id'],
      'ed25519PublicKey': qr['public_key'],
      'x25519PublicKey': qr['x25519_public_key'],
      'anchoringAddress': address,
      'ed25519Signature': await IdentityService.signBytes(utf8.encode(payload)),
      'anchoringSignature': await _signAction(payload),
    });
    return _storage.readAll();
  }

  test(
    'portal dry run, share phase: the app records, encrypts, anchors and shares a clip',
    () async {
      final guardian = await newRegisteredPhone();
      final victim = await newRegisteredPhone();
      final victimNode = victim['public_node_id']!;
      final guardianNode = guardian['public_node_id']!;
      await post('/guardians', {
        'victimNodeId': victimNode,
        'guardianNodeIds': [guardianNode],
        'sequence': 1,
        'signature': await _signAction('justice-chain/set-guardians/v1|$victimNode|1|$guardianNode'),
      });

      // A "recording", sealed exactly as the app seals one.
      final sample = File(Platform.environment['JC_SAMPLE_CLIP'] ?? '');
      final clip = sample.existsSync()
          ? await sample.readAsBytes()
          : utf8.encode('portal dry run ${DateTime.now().toIso8601String()} ${Random().nextInt(1 << 32)}');
      final dir = await Directory.systemTemp.createTemp('portal_live');
      final clipPath = '${dir.path}/clip.mp4';
      await File(clipPath).writeAsBytes(clip);
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        clipPath,
        guardians: [(nodeId: guardianNode, x25519PublicKeyB64: guardian['raw_x25519_public_key']!)],
        threshold: 2,
      );
      final ciphertext = await File(sealed.cipherPath).readAsBytes();
      await dir.delete(recursive: true);

      // Stand-in for the IPFS upload: the portal fetches <IPFS_GATEWAY><cid>.
      final cid = 'bafylocal${_sha256Hex(ciphertext).substring(0, 40)}';
      final ipfs = File('build/portal_ipfs/$cid');
      await ipfs.parent.create(recursive: true);
      await ipfs.writeAsBytes(ciphertext);

      await FabricLedgerService(gatewayUrl: gatewayUrl!).recordAnchor(
        manifestHashHex: sealed.plaintextHash,
        cid: cid,
        capturedAt: sealed.encryptedAt,
        nodeId: victimNode,
        signatureHex: await AnchoringService.signAnchor(sealed.plaintextHash),
      );

      // SimPolice gets a late piece, as the app will when the victim adds it as a guardian.
      final authority = await get('/authorities/SimPoliceMSP') as Map<String, dynamic>;
      final policePiece = await EvidenceEncryptor.issueGuardianShare(
        wrappedKeyB64: sealed.wrappedKeyB64,
        x: sealed.nextShareX,
        guardianX25519PublicKeyB64: authority['publicKey'] as String,
        threshold: sealed.threshold,
      );
      await post('/authority-shares', {
        'manifestHash': sealed.plaintextHash,
        'authorityMsp': 'SimPoliceMSP',
        'shareX': sealed.nextShareX,
        'threshold': sealed.threshold,
        'sealedShare': policePiece,
        'signature': await _signAction('justice-chain/share-with-authority/v1|${sealed.plaintextHash}|SimPoliceMSP|'
            '${sealed.nextShareX}|${sealed.threshold}|${_sha256Hex(base64Decode(policePiece))}'),
      });

      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(jsonEncode({
        'manifestHash': sealed.plaintextHash,
        'clipSha256': _sha256Hex(clip),
        'victim': victim,
        'guardian': guardian,
        'guardianSealedPiece': sealed.guardianShares[guardianNode],
      }));
    },
    skip: gatewayUrl == null || phase != 'share' ? 'Set FABRIC_GATEWAY_URL and JC_LIVE_PHASE=share' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'portal dry run, release phase: the guardian releases piece 1 for the officer\'s request',
    () async {
      final state = jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
      final hash = state['manifestHash'] as String;
      final victim = (state['victim'] as Map).cast<String, String>();
      final guardian = (state['guardian'] as Map).cast<String, String>();

      final requests = (await get('/access-requests/${victim['public_node_id']}') as List)
          .where((r) => r['manifestHash'] == hash && r['status'] == 'open')
          .toList();
      expect(requests, isNotEmpty, reason: 'request access in the portal between the phases');

      _becomePhone(guardian);
      final ownPiece = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: state['guardianSealedPiece'] as String,
        ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
        senderX25519PublicKeyB64: victim['raw_x25519_public_key']!,
      );
      final authority = await get('/authorities/SimPoliceMSP') as Map<String, dynamic>;
      final resealed = await EvidenceEncryptor.sealShare(ownPiece, authority['publicKey'] as String);
      final requestId = requests.first['requestId'] as String;
      final released = await post('/releases', {
        'requestId': requestId,
        'releaserNodeId': guardian['public_node_id'],
        'shareX': ownPiece.x,
        'sealedShare': resealed,
        'signature': await _signAction('justice-chain/release-share/v1|$requestId|$hash|SimPoliceMSP|'
            '${ownPiece.x}|${_sha256Hex(base64Decode(resealed))}'),
      });
      expect(released['status'], 'released');
    },
    skip: gatewayUrl == null || phase != 'release' ? 'Set FABRIC_GATEWAY_URL and JC_LIVE_PHASE=release' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
