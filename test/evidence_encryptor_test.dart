import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/shamir.dart';

// Regression coverage for the Phase 2 fix: recordings must never reach IPFS
// (or any disk location) as plaintext. These tests lock in the full
// encrypt -> wrap -> sign -> delete-plaintext -> decrypt round trip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String plaintextPath;
  const plaintextContent = 'pretend this is a 45-second .mp4 of an incident';

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();

    tempDir = await Directory.systemTemp.createTemp('evidence_encryptor_test');
    plaintextPath = '${tempDir.path}/evidence_test.mp4';
    await File(plaintextPath).writeAsString(plaintextContent);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('encryptAndSeal writes ciphertext that differs from the plaintext', () async {
    final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    final cipherBytes = await File(result.cipherPath).readAsBytes();
    final plaintextBytes = utf8.encode(plaintextContent);

    expect(cipherBytes, isNot(equals(plaintextBytes)));
    expect(
      utf8.decode(cipherBytes, allowMalformed: true),
      isNot(contains(plaintextContent)),
      reason: 'the plaintext content must not appear anywhere in the ciphertext',
    );
  });

  test('encryptAndSeal deletes the plaintext file', () async {
    await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    expect(await File(plaintextPath).exists(), isFalse);
  });

  test('plaintextHash matches a direct SHA-256 of the original content', () async {
    final expectedHash = crypto.sha256.convert(utf8.encode(plaintextContent)).toString();

    final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    expect(result.plaintextHash, expectedHash);
  });

  test('the wrapped key correctly decrypts the ciphertext back to the original bytes', () async {
    final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    final recovered = await EvidenceEncryptor.decryptFile(
      result.cipherPath,
      result.wrappedKeyB64,
    );

    expect(utf8.decode(recovered), plaintextContent);
  });

  test('the signature verifies against the device\'s own Ed25519 public key', () async {
    final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    final payload = await IdentityService.getQrPayload();
    final rawPublicKeyB64 = jsonDecode(payload)['public_key'] as String;
    final publicKey = SimplePublicKey(
      base64Decode(rawPublicKeyB64),
      type: KeyPairType.ed25519,
    );

    final verified = await Ed25519().verify(
      utf8.encode(result.plaintextHash),
      signature: Signature(
        base64Decode(result.signatureB64),
        publicKey: publicKey,
      ),
    );

    expect(verified, isTrue);
  });

  test('unwrapIncidentKey rejects a tampered wrapped key', () async {
    final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

    final tampered = base64Encode(
      List<int>.from(base64Decode(result.wrappedKeyB64))
        ..[0] = (base64Decode(result.wrappedKeyB64)[0] ^ 0xFF),
    );

    expect(
      () => EvidenceEncryptor.decryptFile(result.cipherPath, tampered),
      throwsA(anything),
    );
  });

  group('guardian quorum key sharing', () {
    // Each guardian is simulated as a separate device by generating its
    // X25519 keypair directly, independent of the sender's storage mock.
    late String senderX25519PublicKeyB64;

    setUp(() async {
      final senderPayload = await IdentityService.getQrPayload();
      senderX25519PublicKeyB64 =
          jsonDecode(senderPayload)['x25519_public_key'] as String;
    });

    Future<(SimpleKeyPair, GuardianKeyInfo)> newGuardian(String id) async {
      final keyPair = await X25519().newKeyPair();
      final publicKeyB64 = base64Encode((await keyPair.extractPublicKey()).bytes);
      return (keyPair, (nodeId: id, x25519PublicKeyB64: publicKeyB64));
    }

    Future<ShamirShare> unseal(String sealed, SimpleKeyPair keyPair) {
      return EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: sealed,
        ownX25519KeyPair: keyPair,
        senderX25519PublicKeyB64: senderX25519PublicKeyB64,
      );
    }

    test('any two of three guardians can decrypt together', () async {
      final a = await newGuardian('guardian-a');
      final b = await newGuardian('guardian-b');
      final c = await newGuardian('guardian-c');

      final result = await EvidenceEncryptor.encryptAndSeal(
        plaintextPath,
        guardians: [a.$2, b.$2, c.$2],
      );

      final shareA = await unseal(result.guardianShares['guardian-a']!, a.$1);
      final shareB = await unseal(result.guardianShares['guardian-b']!, b.$1);
      final shareC = await unseal(result.guardianShares['guardian-c']!, c.$1);

      for (final pair in [
        [shareA, shareB],
        [shareA, shareC],
        [shareB, shareC],
      ]) {
        final recovered = await EvidenceEncryptor.decryptFileWithShares(
          cipherPath: result.cipherPath,
          shares: pair,
        );
        expect(utf8.decode(recovered), plaintextContent);
      }
    });

    test('a single guardian share cannot decrypt', () async {
      final a = await newGuardian('guardian-a');
      final result = await EvidenceEncryptor.encryptAndSeal(
        plaintextPath,
        guardians: [a.$2],
      );
      final shareA = await unseal(result.guardianShares['guardian-a']!, a.$1);

      expect(
        () => EvidenceEncryptor.decryptFileWithShares(
          cipherPath: result.cipherPath,
          shares: [shareA],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test("a different guardian's keypair cannot unseal the share", () async {
      final a = await newGuardian('guardian-a');
      final impostor = await X25519().newKeyPair();
      final result = await EvidenceEncryptor.encryptAndSeal(
        plaintextPath,
        guardians: [a.$2],
      );

      expect(
        () => unseal(result.guardianShares['guardian-a']!, impostor),
        throwsA(anything),
      );
    });

    test('a share issued after recording combines with one issued at recording', () async {
      final a = await newGuardian('guardian-a');
      final lateGuardian = await newGuardian('guardian-late');
      final result = await EvidenceEncryptor.encryptAndSeal(
        plaintextPath,
        guardians: [a.$2],
      );

      final lateSealed = await EvidenceEncryptor.issueGuardianShare(
        wrappedKeyB64: result.wrappedKeyB64,
        x: result.nextShareX,
        guardianX25519PublicKeyB64: lateGuardian.$2.x25519PublicKeyB64,
      );

      final recovered = await EvidenceEncryptor.decryptFileWithShares(
        cipherPath: result.cipherPath,
        shares: [
          await unseal(result.guardianShares['guardian-a']!, a.$1),
          await unseal(lateSealed, lateGuardian.$1),
        ],
      );
      expect(utf8.decode(recovered), plaintextContent);
    });

    test('with no guardians passed, guardianShares is empty', () async {
      final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);
      expect(result.guardianShares, isEmpty);
      expect(result.nextShareX, 1);
    });
  });
}
