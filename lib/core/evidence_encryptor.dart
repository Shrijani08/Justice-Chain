import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'identity_service.dart';

/// A guardian's node ID and X25519 public key, as needed to wrap an
/// incident key for them. Guardians paired before X25519 sharing existed
/// have no usable key and should be filtered out before calling
/// [EvidenceEncryptor.encryptAndSeal].
typedef GuardianKeyInfo = ({String nodeId, String x25519PublicKeyB64});

class EncryptedEvidenceResult {
  const EncryptedEvidenceResult({
    required this.cipherPath,
    required this.plaintextHash,
    required this.wrappedKeyB64,
    required this.signatureB64,
    required this.encryptedAt,
    required this.guardianWrappedKeys,
  });

  /// Path to the on-disk ciphertext (nonce + MAC + ciphertext).
  final String cipherPath;

  /// SHA-256 of the original plaintext, hex-encoded. Kept for integrity
  /// checks and as the manifest's content identifier; the plaintext itself
  /// is gone by the time this is returned.
  final String plaintextHash;

  /// The per-incident AES key, wrapped (encrypted) under this device's
  /// vault key-encryption-key. Only this device can unwrap it.
  final String wrappedKeyB64;

  /// Ed25519 signature (base64) over the raw bytes of [plaintextHash],
  /// made with this device's identity key.
  final String signatureB64;

  final DateTime encryptedAt;

  /// The same incident key, wrapped separately for each guardian passed to
  /// [EvidenceEncryptor.encryptAndSeal], keyed by guardian node ID. Empty
  /// when no guardians (with a usable key) were paired at encryption time.
  final Map<String, String> guardianWrappedKeys;
}

/// Encrypts a freshly recorded clip with a random per-incident AES-256-GCM
/// key, wraps that key to the device's own vault key, signs the plaintext's
/// hash, and deletes the plaintext — all before anything leaves the device.
/// A clip must never reach IPFS, a guardian, or disk in a form anyone but
/// this device (today) or a guardian it has wrapped the key for (later
/// phase) can read.
class EvidenceEncryptor {
  EvidenceEncryptor._();

  static Future<EncryptedEvidenceResult> encryptAndSeal(
    String plaintextPath, {
    List<GuardianKeyInfo> guardians = const [],
  }) async {
    final plaintextFile = File(plaintextPath);
    if (!await plaintextFile.exists()) {
      throw ArgumentError('No file at $plaintextPath to encrypt.');
    }

    final plaintextBytes = await plaintextFile.readAsBytes();
    final plaintextHash = crypto.sha256.convert(plaintextBytes).toString();

    final cipherAlgorithm = AesGcm.with256bits();
    final incidentKey = await cipherAlgorithm.newSecretKey();

    final secretBox = await cipherAlgorithm.encrypt(
      plaintextBytes,
      secretKey: incidentKey,
    );

    final cipherPath = '$plaintextPath.enc';
    await File(cipherPath).writeAsBytes(_packSecretBox(secretBox));

    final wrappedKeyB64 = await _wrapIncidentKey(incidentKey);
    final signatureB64 = await IdentityService.signBytes(
      utf8.encode(plaintextHash),
    );

    final guardianWrappedKeys = <String, String>{};
    for (final guardian in guardians) {
      guardianWrappedKeys[guardian.nodeId] = await _wrapIncidentKeyForGuardian(
        incidentKey,
        guardian.x25519PublicKeyB64,
      );
    }

    await plaintextFile.delete();

    return EncryptedEvidenceResult(
      cipherPath: cipherPath,
      plaintextHash: plaintextHash,
      wrappedKeyB64: wrappedKeyB64,
      signatureB64: signatureB64,
      encryptedAt: DateTime.now(),
      guardianWrappedKeys: guardianWrappedKeys,
    );
  }

  /// Encrypts [incidentKey]'s raw bytes under the device's vault key, so
  /// the wrapped value can be stored right alongside the ciphertext without
  /// exposing the key itself.
  static Future<String> _wrapIncidentKey(SecretKey incidentKey) async {
    final vaultKey = await IdentityService.getOrCreateVaultKey();
    final wrapAlgorithm = AesGcm.with256bits();

    final incidentKeyBytes = await incidentKey.extractBytes();
    final wrappedBox = await wrapAlgorithm.encrypt(
      incidentKeyBytes,
      secretKey: vaultKey,
    );

    return base64Encode(_packSecretBox(wrappedBox));
  }

  /// Unwraps a key produced by [_wrapIncidentKey], for decrypting evidence
  /// this device encrypted itself.
  static Future<SecretKey> unwrapIncidentKey(String wrappedKeyB64) async {
    final vaultKey = await IdentityService.getOrCreateVaultKey();
    final wrapAlgorithm = AesGcm.with256bits();

    final wrappedBox = _unpackSecretBox(base64Decode(wrappedKeyB64));
    final keyBytes = await wrapAlgorithm.decrypt(
      wrappedBox,
      secretKey: vaultKey,
    );

    return SecretKey(keyBytes);
  }

  /// Wraps [incidentKey] for a single guardian: a standard "sealed box" —
  /// X25519 key agreement between this device and the guardian's public
  /// key, HKDF to derive a symmetric key from that shared secret, then
  /// AES-GCM. Static-static X25519 (both sides hold long-term keypairs
  /// exchanged at pairing) means the guardian can unwrap it with their own
  /// private key and this device's public key, without ever holding this
  /// device's private key.
  static Future<String> _wrapIncidentKeyForGuardian(
    SecretKey incidentKey,
    String guardianX25519PublicKeyB64,
  ) async {
    final sharedKey = await _deriveGuardianSharedKey(guardianX25519PublicKeyB64);

    final wrapAlgorithm = AesGcm.with256bits();
    final incidentKeyBytes = await incidentKey.extractBytes();
    final wrappedBox = await wrapAlgorithm.encrypt(
      incidentKeyBytes,
      secretKey: sharedKey,
    );

    return base64Encode(_packSecretBox(wrappedBox));
  }

  /// Unwraps a key produced by [_wrapIncidentKeyForGuardian]. Called by a
  /// guardian device, passing its own X25519 keypair and the sender's
  /// public key — the shared secret is identical in both directions.
  static Future<SecretKey> unwrapIncidentKeyFromGuardian({
    required String wrappedKeyB64,
    required SimpleKeyPair ownX25519KeyPair,
    required String senderX25519PublicKeyB64,
  }) async {
    final sharedKey = await _deriveSharedKey(
      ownX25519KeyPair,
      senderX25519PublicKeyB64,
    );

    final wrapAlgorithm = AesGcm.with256bits();
    final wrappedBox = _unpackSecretBox(base64Decode(wrappedKeyB64));
    final keyBytes = await wrapAlgorithm.decrypt(
      wrappedBox,
      secretKey: sharedKey,
    );

    return SecretKey(keyBytes);
  }

  /// Derives the sealed-box wrapping key between this device and
  /// [remoteX25519PublicKeyB64], using this device's own stored keypair.
  static Future<SecretKey> _deriveGuardianSharedKey(
    String remoteX25519PublicKeyB64,
  ) async {
    final ownKeyPair = await IdentityService.getX25519KeyPair();
    return _deriveSharedKey(ownKeyPair, remoteX25519PublicKeyB64);
  }

  static Future<SecretKey> _deriveSharedKey(
    SimpleKeyPair ownKeyPair,
    String remoteX25519PublicKeyB64,
  ) async {
    final remotePublicKey = SimplePublicKey(
      base64Decode(remoteX25519PublicKeyB64),
      type: KeyPairType.x25519,
    );

    final rawSharedSecret = await X25519().sharedSecretKey(
      keyPair: ownKeyPair,
      remotePublicKey: remotePublicKey,
    );

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: rawSharedSecret,
      info: utf8.encode('justice-chain-guardian-wrap-v1'),
    );
  }

  /// Decrypts a `.enc` file written by [encryptAndSeal], given its wrapped
  /// key. Used by this device to review its own evidence later.
  static Future<Uint8List> decryptFile(
    String cipherPath,
    String wrappedKeyB64,
  ) async {
    final incidentKey = await unwrapIncidentKey(wrappedKeyB64);
    return _decryptFileWithKey(cipherPath, incidentKey);
  }

  /// Decrypts a `.enc` file as a guardian: unwraps the incident key from
  /// its guardian-wrapped share (see [unwrapIncidentKeyFromGuardian]) and
  /// decrypts the ciphertext with it.
  static Future<Uint8List> decryptFileAsGuardian({
    required String cipherPath,
    required String wrappedKeyB64,
    required SimpleKeyPair ownX25519KeyPair,
    required String senderX25519PublicKeyB64,
  }) async {
    final incidentKey = await unwrapIncidentKeyFromGuardian(
      wrappedKeyB64: wrappedKeyB64,
      ownX25519KeyPair: ownX25519KeyPair,
      senderX25519PublicKeyB64: senderX25519PublicKeyB64,
    );
    return _decryptFileWithKey(cipherPath, incidentKey);
  }

  static Future<Uint8List> _decryptFileWithKey(
    String cipherPath,
    SecretKey incidentKey,
  ) async {
    final cipherBytes = await File(cipherPath).readAsBytes();
    final secretBox = _unpackSecretBox(cipherBytes);

    final cipherAlgorithm = AesGcm.with256bits();
    final plaintext = await cipherAlgorithm.decrypt(
      secretBox,
      secretKey: incidentKey,
    );

    return Uint8List.fromList(plaintext);
  }

  /// Serializes a [SecretBox] as nonce(12B) + mac(16B) + ciphertext, so it
  /// can live as a single opaque blob on disk or in a string field.
  static Uint8List _packSecretBox(SecretBox box) {
    final builder = BytesBuilder();
    builder.add(box.nonce);
    builder.add(box.mac.bytes);
    builder.add(box.cipherText);
    return builder.toBytes();
  }

  static SecretBox _unpackSecretBox(List<int> packed) {
    const nonceLength = 12;
    const macLength = 16;

    if (packed.length < nonceLength + macLength) {
      throw ArgumentError('Packed box too short to contain nonce and MAC.');
    }

    final nonce = packed.sublist(0, nonceLength);
    final mac = packed.sublist(nonceLength, nonceLength + macLength);
    final cipherText = packed.sublist(nonceLength + macLength);

    return SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  }
}
