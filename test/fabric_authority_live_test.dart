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

// Step 8 against the live gateway, signed and sealed by the app's own code:
// a fresh phone registers, anchors a clip, and gives SimPolice one sealed
// key piece. The piece it sealed is written to build/authority_live_share.json
// so the officer-side check (fabric/network/check-authority-share.sh) can
// confirm SimPolice unseals exactly this piece.
//
// Each run registers one new test node and anchors one test clip; both
// stay on the ledger permanently.
//   FABRIC_GATEWAY_URL=http://localhost:8800 flutter test test/fabric_authority_live_test.dart

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<String> _signAction(String payload) =>
    AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding (needed for the secure-storage mock) fakes every HTTP call;
  // this test talks to the real gateway.
  HttpOverrides.global = null;
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];

  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async {
    final response = await http.post(
      Uri.parse('$gatewayUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError('POST $path -> ${response.statusCode}: ${decoded['error']}');
    }
    return decoded;
  }

  Future<dynamic> get(String path) async =>
      jsonDecode((await http.get(Uri.parse('$gatewayUrl$path'))).body);

  test(
    'live: a registered phone shares one sealed key piece with SimPolice',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      IdentityService.resetCacheForTest();
      await IdentityService.initializeDevice();
      final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
      final nodeId = qr['node_id'] as String;
      final edKey = qr['public_key'] as String;
      final xKey = qr['x25519_public_key'] as String;
      final address = (qr['anchoring_address'] as String).toLowerCase();

      // 1. Register the phone, signed by both of its keys.
      final registration = 'justice-chain/register-node/v1|$nodeId|$edKey|$xKey|$address';
      final node = await post('/nodes', {
        'nodeId': nodeId,
        'ed25519PublicKey': edKey,
        'x25519PublicKey': xKey,
        'anchoringAddress': address,
        'ed25519Signature': await IdentityService.signBytes(utf8.encode(registration)),
        'anchoringSignature': await _signAction(registration),
      });
      expect(node['anchoringAddress'], address);
      expect((await get('/nodes/$nodeId'))['found'], isTrue);

      // 2. Anchor a clip, as the app does after an upload.
      final hash = _sha256Hex(utf8.encode('step 8 live ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}'));
      await FabricLedgerService(gatewayUrl: gatewayUrl!).recordAnchor(
        manifestHashHex: hash,
        cid: 'bafystep8livetest',
        capturedAt: DateTime.now(),
        nodeId: nodeId,
        signatureHex: await AnchoringService.signAnchor(hash),
      );

      // 3. One Shamir piece (index 3 of a 2-of-n key), sealed to SimPolice's desk key.
      final authority = await get('/authorities/SimPoliceMSP') as Map<String, dynamic>;
      expect(authority['found'], isTrue);
      expect(authority['name'], contains('(SIMULATED)'));
      final random = Random.secure();
      final incidentKey = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      final coefficient = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      final share = Shamir.shareAt(secret: incidentKey, coefficients: [coefficient], x: 3);
      final sealed = await EvidenceEncryptor.sealShare(share, authority['publicKey'] as String);

      // 4. The victim's consent covers this exact piece and authority.
      final consentPayload = 'justice-chain/share-with-authority/v1|$hash|SimPoliceMSP|3|2|'
          '${_sha256Hex(base64Decode(sealed))}';
      final consent = await post('/authority-shares', {
        'manifestHash': hash,
        'authorityMsp': 'SimPoliceMSP',
        'shareX': 3,
        'threshold': 2,
        'sealedShare': sealed,
        'signature': await _signAction(consentPayload),
      });
      expect(consent['victimNodeId'], nodeId);
      expect(consent['shareHash'], _sha256Hex(base64Decode(sealed)));
      expect(consent['blockNumber'], greaterThan(0));
      expect(jsonEncode(consent).contains(sealed), isFalse);

      final listed = await get('/authority-shares/SimPoliceMSP') as List;
      expect(listed.map((c) => c['manifestHash']), contains(hash));
      expect(jsonEncode(listed).contains(sealed), isFalse);

      await expectLater(
        post('/authority-shares', {
          'manifestHash': hash,
          'authorityMsp': 'SimPoliceMSP',
          'shareX': 3,
          'threshold': 2,
          'sealedShare': sealed,
          'signature': await _signAction(consentPayload),
        }),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('already shared'))),
      );

      final out = File('build/authority_live_share.json');
      await out.parent.create(recursive: true);
      await out.writeAsString(jsonEncode({
        'manifestHash': hash,
        'blockNumber': consent['blockNumber'],
        'sealedShare': sealed,
        'x': share.x,
        'yHex': share.y.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      }));
    },
    skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
