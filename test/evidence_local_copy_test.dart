import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';

// Once a clip is on IPFS and anchored, the phone deletes its own encrypted
// copy; My evidence then plays it by downloading it again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box vault;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('local_copy_test');
    Hive.init(tempDir.path);
    vault = await Hive.openBox('vault_box');
    await Hive.openBox(OutboxService.boxName);
    await Hive.openBox(MeshService.relayBoxName);
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
  });

  tearDown(() async {
    EvidenceVaultService.clientForTest = null;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// A sealed clip saved in the vault with [status], as the recording flow does.
  Future<({String hash, Uint8List plaintext, Uint8List cipher, String path})> sealedClip(String status) async {
    final plaintext = Uint8List.fromList(List<int>.generate(5000, (_) => Random().nextInt(256)));
    final clip = File('${tempDir.path}/clip_${Random().nextInt(1 << 30)}.mp4')..writeAsBytesSync(plaintext);
    final sealed = await EvidenceEncryptor.encryptAndSeal(clip.path);
    await vault.put(sealed.plaintextHash, {
      'path': sealed.cipherPath,
      'hash': sealed.plaintextHash,
      'wrappedKey': sealed.wrappedKeyB64,
      'signature': sealed.signatureB64,
      'guardianShares': sealed.guardianShares,
      'threshold': sealed.threshold,
      'timestamp': sealed.encryptedAt.toIso8601String(),
      'status': status,
      'cid': status == 'locally_secured' ? null : 'QmClip',
    });
    return (hash: sealed.plaintextHash, plaintext: plaintext, cipher: File(sealed.cipherPath).readAsBytesSync(), path: sealed.cipherPath);
  }

  test('an anchored clip loses its local copy but keeps its record and key', () async {
    final clip = await sealedClip('anchored');
    await EvidenceVaultService.resumePendingWork();

    expect(File(clip.path).existsSync(), isFalse);
    final record = vault.get(clip.hash) as Map;
    expect(record['localCopyDeleted'], isTrue);
    expect(record['wrappedKey'], isNotNull);
  });

  test('a clip not yet anchored keeps its local copy', () async {
    final uploaded = await sealedClip('uploaded_to_ipfs');
    final pending = await sealedClip('locally_secured');
    await EvidenceVaultService.resumePendingWork();

    expect(File(uploaded.path).existsSync(), isTrue);
    expect(File(pending.path).existsSync(), isTrue);
  });

  test('My evidence plays a deleted clip by downloading it from IPFS', () async {
    final clip = await sealedClip('anchored');
    await EvidenceVaultService.resumePendingWork();
    EvidenceVaultService.clientForTest = MockClient(
      (r) async => r.url.path.endsWith('/QmClip') ? http.Response.bytes(clip.cipher, 200) : http.Response('', 404),
    );

    expect(await EvidenceVaultService.openOwnClip(clip.hash), clip.plaintext);
  });

  test('a download that is not the recorded clip is refused', () async {
    final clip = await sealedClip('anchored');
    final other = await sealedClip('anchored');
    await EvidenceVaultService.resumePendingWork();
    EvidenceVaultService.clientForTest = MockClient((_) async => http.Response.bytes(other.cipher, 200));

    await expectLater(EvidenceVaultService.openOwnClip(clip.hash), throwsA(anything));
  });

  test('a clip still on the phone plays from the local copy without downloading', () async {
    final clip = await sealedClip('uploaded_to_ipfs');
    EvidenceVaultService.clientForTest = MockClient((_) async => throw StateError('should not download'));

    expect(await EvidenceVaultService.openOwnClip(clip.hash), clip.plaintext);
  });

  test("a guardian's relayed copy is deleted once anchored, and kept until then", () async {
    final relays = Hive.box(MeshService.relayBoxName);
    Future<File> relayed(String hash, String status) async {
      final file = File('${tempDir.path}/$hash.enc')..writeAsBytesSync([1, 2, 3]);
      await relays.put(hash, {'path': file.path, 'status': status, 'cid': status == 'relay_received' ? null : 'QmRelay'});
      return file;
    }

    final anchored = await relayed('a' * 64, 'relay_anchored');
    final uploaded = await relayed('b' * 64, 'relay_uploaded');
    final received = await relayed('c' * 64, 'relay_received');
    await EvidenceVaultService.resumePendingWork();

    expect(anchored.existsSync(), isFalse);
    expect((relays.get('a' * 64) as Map)['localCopyDeleted'], isTrue);
    expect(uploaded.existsSync(), isTrue);
    expect(received.existsSync(), isTrue);
  });
}
