import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';

const _otherSigner = '0x1111111111111111111111111111111111111111';

AnchorVerificationResult _anchor(String signer, {String cid = 'QmClip', List<AnchorVerificationResult> claims = const []}) =>
    AnchorVerificationResult(
      found: true,
      cid: cid,
      capturedAt: DateTime(2026),
      anchoredAt: DateTime(2026),
      nodeId: '0123456789abcdef',
      signer: signer,
      claims: claims,
    );

/// A ledger whose look-up answer the test sets, and that records anchors.
class _Ledger implements LedgerService {
  AnchorVerificationResult? onChain;
  int anchors = 0;

  @override
  String get name => 'fake';

  @override
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  }) async {
    anchors++;
    return 'tx-$anchors';
  }

  @override
  Future<AnchorVerificationResult> verifyEvidence(String manifestHashHex) async =>
      onChain ??
      AnchorVerificationResult(
        found: false,
        cid: '',
        capturedAt: DateTime(1970),
        anchoredAt: DateTime(1970),
        nodeId: '',
        signer: '',
      );

  @override
  Future<AnchorBlock?> findAnchorBlock(String manifestHashHex) async => null;

  @override
  Future<List<String>> getEvidenceHistory(String nodeId) async => const [];
}

// Whoever anchors a clip first holds the ledger record (chaincode 1.7 keeps
// later signers as claims). The phone must not take someone else's anchor
// as its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box vault;
  late _Ledger ledger;
  late String myAddress;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('anchor_claim_test');
    Hive.init(tempDir.path);
    vault = await Hive.openBox('vault_box');
    await Hive.openBox(OutboxService.boxName);
    await Hive.openBox(MeshService.relayBoxName);
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
    myAddress = (await IdentityService.getAnchoringCredentials()).address.eip55With0x;
    AnchoringService.ledgerForTest = ledger = _Ledger();
  });

  tearDown(() async {
    AnchoringService.ledgerForTest = null;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> uploadedClip() async {
    final clip = File('${tempDir.path}/clip.mp4')
      ..writeAsBytesSync(Uint8List.fromList(List<int>.generate(2000, (_) => Random().nextInt(256))));
    final sealed = await EvidenceEncryptor.encryptAndSeal(clip.path);
    await vault.put(sealed.plaintextHash, {
      'path': sealed.cipherPath,
      'hash': sealed.plaintextHash,
      'wrappedKey': sealed.wrappedKeyB64,
      'timestamp': sealed.encryptedAt.toIso8601String(),
      'status': 'uploaded_to_ipfs',
      'cid': 'QmClip',
    });
    return sealed.plaintextHash;
  }

  test('a clip someone else anchored first is still anchored by this phone, and flagged', () async {
    final hash = await uploadedClip();
    ledger.onChain = _anchor(_otherSigner);

    await EvidenceVaultService.anchorRecord(hash);

    expect(ledger.anchors, 1, reason: 'the phone adds its own signature as a claim');
    final record = vault.get(hash) as Map;
    expect(record['status'], 'anchored');
    expect(record['anchorConflict'], _otherSigner);
  });

  test("the phone's own anchor, as the record or as a claim, is not repeated", () async {
    final hash = await uploadedClip();
    ledger.onChain = _anchor(myAddress.toLowerCase());
    await EvidenceVaultService.anchorRecord(hash);
    expect(ledger.anchors, 0);
    expect((vault.get(hash) as Map)['anchorConflict'], isNull);

    final second = await uploadedClip();
    ledger.onChain = _anchor(_otherSigner, claims: [_anchor(myAddress)]);
    await EvidenceVaultService.anchorRecord(second);
    expect(ledger.anchors, 0);
    expect((vault.get(second) as Map)['status'], 'anchored');
    expect((vault.get(second) as Map)['anchorConflict'], _otherSigner);
  });

  test('bySigner finds the record or a claim, ignoring case', () {
    final claim = _anchor(myAddress, cid: 'QmMine');
    final result = _anchor(_otherSigner, cid: 'QmTheirs', claims: [claim]);
    expect(result.bySigner(myAddress.toUpperCase().replaceFirst('0X', '0x'))?.cid, 'QmMine');
    expect(result.bySigner(_otherSigner)?.cid, 'QmTheirs');
    expect(result.bySigner('0x2222222222222222222222222222222222222222'), isNull);
  });
}
