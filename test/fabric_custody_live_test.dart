import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/shamir.dart';

// Step 9 against the live gateway, with the app's own keys, signing and
// sealing, in two phases around the officer's request (made with the
// officer's Fabric identity by fabric/network/check-custody.sh):
//
//   JC_LIVE_PHASE=share    a victim and a guardian register; the victim
//                          sets the guardian, anchors a clip, seals piece 1
//                          to the guardian (as at recording) and shares
//                          piece 3 with SimPolice.
//   (check-custody.sh request: officer1 files two access requests)
//   JC_LIVE_PHASE=release  the guardian unseals piece 1, re-seals it to
//                          SimPolice and releases it for request 1; a forged
//                          release is refused; request 2 gets a valid signed
//                          release that is NOT submitted, for the check that
//                          the Auditor's endorsement is required.
//   (check-custody.sh verify: officer recombines pieces 1 and 3 into the key)
//
// State passes between phases in build/custody_live_state.json (test keys
// only). Each run leaves its test nodes, clip and requests on the ledger.
//   FABRIC_GATEWAY_URL=http://localhost:8800 JC_LIVE_PHASE=share flutter test test/fabric_custody_live_test.dart

final _stateFile = File('build/custody_live_state.json');
const _storage = FlutterSecureStorage();

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<String> _signAction(String payload) => AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload)));

/// Makes [storage] the device's keys, as if the app ran on that phone.
void _becomePhone(Map<String, String> storage) {
  FlutterSecureStorage.setMockInitialValues(storage);
  IdentityService.resetCacheForTest();
}

/// A fresh phone's keys, and its registration on the ledger.
Future<Map<String, String>> _newRegisteredPhone(Future<Map<String, dynamic>> Function(String, Object) post) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding (needed for the secure-storage mock) fakes every HTTP call;
  // this test talks to the real gateway.
  HttpOverrides.global = null;
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];
  final gatewayKey = {'X-Api-Key': Platform.environment['FABRIC_GATEWAY_API_KEY'] ?? ''};
  final phase = Platform.environment['JC_LIVE_PHASE'];

  Future<Map<String, dynamic>> post(String path, Object body) async {
    final response = await http.post(Uri.parse('$gatewayUrl$path'),
        headers: {...gatewayKey, 'Content-Type': 'application/json'}, body: jsonEncode(body));
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError('POST $path -> ${response.statusCode}: ${decoded['error']}');
    }
    return decoded;
  }

  Future<dynamic> get(String path) async => jsonDecode((await http.get(Uri.parse('$gatewayUrl$path'), headers: gatewayKey)).body);

  test(
    'live custody, share phase: victim and guardian register, victim shares piece 3 with SimPolice',
    () async {
      final guardian = await _newRegisteredPhone(post);
      final victim = await _newRegisteredPhone(post);

      // The victim's phone is now the device; it names its guardian.
      final victimNode = victim['public_node_id']!;
      final guardianNode = guardian['public_node_id']!;
      final list = await post('/guardians', {
        'victimNodeId': victimNode,
        'guardianNodeIds': [guardianNode],
        'sequence': 1,
        'signature': await _signAction('justice-chain/set-guardians/v1|$victimNode|1|$guardianNode'),
      });
      expect(list['guardians'], [guardianNode]);

      final hash = _sha256Hex(utf8.encode('step 9 live ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}'));
      await FabricLedgerService(gatewayUrl: gatewayUrl!, apiKey: Platform.environment['FABRIC_GATEWAY_API_KEY']).recordAnchor(
        manifestHashHex: hash,
        cid: 'bafystep9livetest',
        capturedAt: DateTime.now(),
        nodeId: victimNode,
        signatureHex: await AnchoringService.signAnchor(hash),
      );

      // A 2-of-n incident key: piece 1 for the guardian (as at recording), piece 3 for SimPolice.
      final random = Random.secure();
      final incidentKey = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      final coefficients = [Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)))];
      final guardianPiece = await EvidenceEncryptor.sealShare(
        Shamir.shareAt(secret: incidentKey, coefficients: coefficients, x: 1),
        guardian['raw_x25519_public_key']!,
      );
      final authority = await get('/authorities/SimPoliceMSP') as Map<String, dynamic>;
      final policePiece = await EvidenceEncryptor.sealShare(
        Shamir.shareAt(secret: incidentKey, coefficients: coefficients, x: 3),
        authority['publicKey'] as String,
      );
      await post('/authority-shares', {
        'manifestHash': hash,
        'authorityMsp': 'SimPoliceMSP',
        'shareX': 3,
        'threshold': 2,
        'sealedShare': policePiece,
        'signature': await _signAction('justice-chain/share-with-authority/v1|$hash|SimPoliceMSP|3|2|'
            '${_sha256Hex(base64Decode(policePiece))}'),
      });

      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(jsonEncode({
        'manifestHash': hash,
        'incidentKeyHex': _hex(incidentKey),
        'victim': victim,
        'guardian': guardian,
        'guardianSealedPiece': guardianPiece,
      }));
    },
    skip: gatewayUrl == null || phase != 'share' ? 'Set FABRIC_GATEWAY_URL and JC_LIVE_PHASE=share' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'live custody, release phase: the guardian releases piece 1 for the officer\'s request',
    () async {
      final state = jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
      final hash = state['manifestHash'] as String;
      final victim = (state['victim'] as Map).cast<String, String>();
      final guardian = (state['guardian'] as Map).cast<String, String>();
      final requestIds = (state['requestIds'] as List).cast<String>();
      expect(requestIds, hasLength(2), reason: 'run check-custody.sh request between the phases');

      final requests = await get('/access-requests/${victim['public_node_id']}') as List;
      expect(requests.map((r) => r['requestId']), containsAll(requestIds));
      expect(requests.firstWhere((r) => r['requestId'] == requestIds[0])['status'], 'open');

      // The guardian's phone: unseal its own piece, re-seal it to SimPolice.
      _becomePhone(guardian);
      final ownPiece = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: state['guardianSealedPiece'] as String,
        ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
        senderX25519PublicKeyB64: victim['raw_x25519_public_key']!,
      );
      expect(ownPiece.x, 1);
      final authority = await get('/authorities/SimPoliceMSP') as Map<String, dynamic>;
      final resealed = await EvidenceEncryptor.sealShare(ownPiece, authority['publicKey'] as String);
      final pieceHash = _sha256Hex(base64Decode(resealed));
      String releasePayload(String requestId) =>
          'justice-chain/release-share/v1|$requestId|$hash|SimPoliceMSP|1|$pieceHash';

      // A release signed by the victim's key but claiming to be the guardian is refused.
      _becomePhone(victim);
      final forged = await _signAction(releasePayload(requestIds[0]));
      _becomePhone(guardian);
      await expectLater(
        post('/releases', {
          'requestId': requestIds[0],
          'releaserNodeId': guardian['public_node_id'],
          'shareX': 1,
          'sealedShare': resealed,
          'signature': forged,
        }),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not signed by the releaser'))),
      );

      final body = {
        'requestId': requestIds[0],
        'releaserNodeId': guardian['public_node_id'],
        'shareX': 1,
        'sealedShare': resealed,
        'signature': await _signAction(releasePayload(requestIds[0])),
      };
      final released = await post('/releases', body);
      expect(released['status'], 'released');
      expect(released['releaserRole'], 'guardian');
      expect(released['blockNumber'], greaterThan(0));
      expect(jsonEncode(released).contains(resealed), isFalse);

      // A retry (e.g. after a dropped connection) is harmless.
      expect((await post('/releases', body))['status'], 'released');

      state['releasedPieceHash'] = pieceHash;
      state['releasedSealedPiece'] = resealed;
      state['deliveryBlock'] = (released['delivery'] as Map)['blockNumber'];
      state['unsubmittedRelease'] = {
        'requestId': requestIds[1],
        'releaserNodeId': guardian['public_node_id'],
        'shareX': 1,
        'shareHash': pieceHash,
        'signature': await _signAction(releasePayload(requestIds[1])),
      };
      await _stateFile.writeAsString(jsonEncode(state));
    },
    skip: gatewayUrl == null || phase != 'release' ? 'Set FABRIC_GATEWAY_URL and JC_LIVE_PHASE=release' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
