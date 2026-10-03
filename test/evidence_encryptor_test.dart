import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';

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

  group('guardian key sharing', () {
    // These simulate a second physical device (the guardian) by generating
    // its X25519 keypair directly, independent of the sender's secure
    // storage mock — unwrapIncidentKeyFromGuardian takes the guardian's
    // keypair as an explicit parameter for exactly this reason.
    test(
      'a guardian can unwrap and decrypt using only their own keypair and '
      "the sender's public key — never the sender's private key",
      () async {
        final guardianKeyPair = await X25519().newKeyPair();
        final guardianPublicKeyB64 = base64Encode(
          (await guardianKeyPair.extractPublicKey()).bytes,
        );

        final result = await EvidenceEncryptor.encryptAndSeal(
          plaintextPath,
          guardians: [
            (nodeId: 'guardian-1', x25519PublicKeyB64: guardianPublicKeyB64),
          ],
        );

        expect(result.guardianWrappedKeys, contains('guardian-1'));

        final senderPayload = await IdentityService.getQrPayload();
        final senderX25519PublicKeyB64 =
            jsonDecode(senderPayload)['x25519_public_key'] as String;

        final recovered = await EvidenceEncryptor.decryptFileAsGuardian(
          cipherPath: result.cipherPath,
          wrappedKeyB64: result.guardianWrappedKeys['guardian-1']!,
          ownX25519KeyPair: guardianKeyPair,
          senderX25519PublicKeyB64: senderX25519PublicKeyB64,
        );

        expect(utf8.decode(recovered), plaintextContent);
      },
    );

    test('a different guardian\'s keypair cannot unwrap the share', () async {
      final guardianKeyPair = await X25519().newKeyPair();
      final guardianPublicKeyB64 = base64Encode(
        (await guardianKeyPair.extractPublicKey()).bytes,
      );
      final impostorKeyPair = await X25519().newKeyPair();

      final result = await EvidenceEncryptor.encryptAndSeal(
        plaintextPath,
        guardians: [
          (nodeId: 'guardian-1', x25519PublicKeyB64: guardianPublicKeyB64),
        ],
      );

      final senderPayload = await IdentityService.getQrPayload();
      final senderX25519PublicKeyB64 =
          jsonDecode(senderPayload)['x25519_public_key'] as String;

      expect(
        () => EvidenceEncryptor.decryptFileAsGuardian(
          cipherPath: result.cipherPath,
          wrappedKeyB64: result.guardianWrappedKeys['guardian-1']!,
          ownX25519KeyPair: impostorKeyPair,
          senderX25519PublicKeyB64: senderX25519PublicKeyB64,
        ),
        throwsA(anything),
      );
    });

    test('with no guardians passed, guardianWrappedKeys is empty', () async {
      final result = await EvidenceEncryptor.encryptAndSeal(plaintextPath);

      expect(result.guardianWrappedKeys, isEmpty);
    });

    test(
      'wrapping for two guardians produces independently-unwrappable shares',
      () async {
        final guardianA = await X25519().newKeyPair();
        final guardianB = await X25519().newKeyPair();
        final guardianAPublicKeyB64 = base64Encode(
          (await guardianA.extractPublicKey()).bytes,
        );
        final guardianBPublicKeyB64 = base64Encode(
          (await guardianB.extractPublicKey()).bytes,
        );

        final result = await EvidenceEncryptor.encryptAndSeal(
          plaintextPath,
          guardians: [
            (nodeId: 'guardian-a', x25519PublicKeyB64: guardianAPublicKeyB64),
            (nodeId: 'guardian-b', x25519PublicKeyB64: guardianBPublicKeyB64),
          ],
        );

        expect(result.guardianWrappedKeys.keys, {'guardian-a', 'guardian-b'});

        final senderPayload = await IdentityService.getQrPayload();
        final senderX25519PublicKeyB64 =
            jsonDecode(senderPayload)['x25519_public_key'] as String;

        final recoveredByA = await EvidenceEncryptor.decryptFileAsGuardian(
          cipherPath: result.cipherPath,
          wrappedKeyB64: result.guardianWrappedKeys['guardian-a']!,
          ownX25519KeyPair: guardianA,
          senderX25519PublicKeyB64: senderX25519PublicKeyB64,
        );
        final recoveredByB = await EvidenceEncryptor.decryptFileAsGuardian(
          cipherPath: result.cipherPath,
          wrappedKeyB64: result.guardianWrappedKeys['guardian-b']!,
          ownX25519KeyPair: guardianB,
          senderX25519PublicKeyB64: senderX25519PublicKeyB64,
        );

        expect(utf8.decode(recoveredByA), plaintextContent);
        expect(utf8.decode(recoveredByB), plaintextContent);
      },
    );
  });
}
