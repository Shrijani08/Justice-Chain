import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/core/recovery_service.dart';

// Option 1 (recovery code) against the live Fabric network: a phone records
// two clips with no guardians and anchors them through the app's own path;
// a brand-new phone given only the recovery code restores the identity,
// lists the clips from the ledger (/history) and opens each from IPFS,
// byte for byte.
//
// Needs the gateway (8800) and a static server on 8901 serving
// build/portal_ipfs (the IPFS stand-in), where this test puts the
// ciphertext. Each run anchors two test clips (permanent).
//   FABRIC_GATEWAY_URL=http://localhost:8800 flutter test test/recovery_live_test.dart

Future<void> _newPhone() async {
  FlutterSecureStorage.setMockInitialValues({});
  IdentityService.resetCacheForTest();
  await IdentityService.initializeDevice();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // talk to the real gateway and IPFS stand-in
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];

  test(
    'live: a new phone with only the recovery code gets the clips back from the ledger',
    () async {
      dotenv.loadFromString(envString: 'IPFS_GATEWAY=http://127.0.0.1:8901/');
      final tempDir = await Directory.systemTemp.createTemp('recovery_live');
      Hive.init(tempDir.path);
      final vault = await Hive.openBox('vault_box');
      await Hive.openBox(OutboxService.boxName);
      AnchoringService.ledgerForTest = FabricLedgerService(gatewayUrl: gatewayUrl!);

      try {
        // The old phone: no guardians, records and anchors two clips.
        await _newPhone();
        final code = (await IdentityService.pendingRecoveryCode())!;
        await IdentityService.confirmRecoveryCodeSaved();
        final oldNode = await IdentityService.getMyNodeId();
        final clips = <String, List<int>>{};
        for (final label in ['first', 'second']) {
          final dir = await Directory.systemTemp.createTemp('clip');
          final bytes = utf8.encode('recovery live $label ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}');
          final clip = File('${dir.path}/clip.mp4')..writeAsBytesSync(bytes);
          final sealed = await EvidenceEncryptor.encryptAndSeal(clip.path);
          final key = sealed.plaintextHash;
          final cid = 'bafyrecovery${key.substring(0, 16)}';
          await File(sealed.cipherPath).copy('build/portal_ipfs/$cid');
          await vault.put(key, {
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
          expect((vault.get(key) as Map)['status'], 'anchored');
          clips[key] = bytes;
        }

        // The phone is lost: everything on it is gone.
        await vault.clear();
        await _newPhone();
        expect(await IdentityService.getMyNodeId(), isNot(oldNode));

        // A new phone, given only the code.
        final found = await RecoveryService.restore(code: code, name: 'Live restore', pin: '2580');
        expect(await IdentityService.getMyNodeId(), oldNode);
        expect(found, greaterThanOrEqualTo(2));
        for (final entry in clips.entries) {
          expect((vault.get(entry.key) as Map)['status'], RecoveryService.restoredStatus);
          expect(await RecoveryService.openRestoredClip(entry.key), entry.value);
        }
      } finally {
        AnchoringService.ledgerForTest = null;
        await Hive.deleteFromDisk();
        await Hive.close();
      }
    },
    skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
