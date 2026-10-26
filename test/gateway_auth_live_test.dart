import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/gateway_auth.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/pinata_service.dart';

// The app with no shared secret (judge review S1/S2): a fresh phone
// registers, then signs every gateway request with its own key, uploads a
// clip through a one-time Pinata URL, anchors it, and is refused another
// phone's records. Uploads one tiny file to Pinata and anchors it (both
// permanent test data). Run with the live gateway:
//   FABRIC_GATEWAY_URL=http://localhost:8800 flutter test test/gateway_auth_live_test.dart

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];

  test('the payload a phone signs matches the gateway format', () async {
    final payload = GatewayAuth.payload('POST', '/upload-url', 1800000000, utf8.encode('{"size":10}'));
    expect(payload, startsWith('justice-chain/request/v1|POST|/upload-url|1800000000|'));
    expect(payload.split('|').last, hasLength(64));

    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
    final headers = await GatewayAuth.sign('GET', '/history/x', const []);
    expect(headers['X-Node-Id'], await IdentityService.getMyNodeId());
    final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
    final ok = await Ed25519().verify(
      utf8.encode(GatewayAuth.payload('GET', '/history/x', int.parse(headers['X-Timestamp']!), const [])),
      signature: Signature(
        base64Decode(headers['X-Signature']!),
        publicKey: SimplePublicKey(base64Decode(qr['public_key'] as String), type: KeyPairType.ed25519),
      ),
    );
    expect(ok, isTrue);
  });

  group('live', () {
    late Directory tempDir;
    late FabricLedgerService gateway;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gateway_auth_live');
      Hive.init(tempDir.path);
      await Hive.openBox('vault_box');
      FlutterSecureStorage.setMockInitialValues({});
      IdentityService.resetCacheForTest();
      await IdentityService.initializeDevice();
      // Exactly what the app builds: no API key, only the phone's signature.
      gateway = FabricLedgerService(gatewayUrl: gatewayUrl!, signer: GatewayAuth.sign);
      AuthorityService.gatewayForTest = gateway;
      AnchoringService.ledgerForTest = gateway;
      PinataService.uploadUrlForTest = gateway.uploadUrl;
    });

    tearDown(() async {
      AuthorityService.gatewayForTest = null;
      AnchoringService.ledgerForTest = null;
      PinataService.uploadUrlForTest = null;
      await Hive.deleteFromDisk();
      await Hive.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a phone without the API key registers, uploads, anchors, and reads only its own records', () async {
      final me = await IdentityService.getMyNodeId();

      // Before registering, a signed request is not recognised.
      await expectLater(gateway.getEvidenceHistory(me), throwsA(isA<StateError>()));

      await AuthorityService.registerThisPhone();
      expect(await gateway.getEvidenceHistory(me), isEmpty);

      final clip = File('${tempDir.path}/clip.enc')
        ..writeAsBytesSync(List<int>.generate(256, (_) => Random().nextInt(256)));
      final cid = await PinataService.uploadToIPFS(clip.path);
      expect(cid, startsWith('baf'));

      final hash = List.generate(32, (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final txId = await AnchoringService.recordAnchor(
        manifestHashHex: hash,
        cid: cid,
        capturedAt: DateTime.now(),
        nodeId: me,
      );
      expect(txId, isNotNull);
      expect(await gateway.getEvidenceHistory(me), [hash]);
      final mine = (await gateway.verifyEvidence(hash)).bySigner(
        (await IdentityService.getAnchoringCredentials()).address.eip55With0x,
      );
      expect(mine?.cid, cid);

      // Another phone's records are refused (HTTP 403).
      await expectLater(gateway.getEvidenceHistory('0123456789abcdef'), throwsA(isA<StateError>()));
      await expectLater(gateway.getGuardians('0123456789abcdef'), throwsA(isA<StateError>()));
    });
  }, skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway' : null);
}
