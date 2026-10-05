import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'identity_service.dart';
import 'shamir.dart';

/// A guardian's node ID and X25519 public key, as needed to wrap a key
/// share for them. Guardians paired before X25519 sharing existed have no
/// usable key and should be filtered out before calling
/// [EvidenceEncryptor.encryptAndSeal].
typedef GuardianKeyInfo = ({String nodeId, String x25519PublicKeyB64});

class EncryptedEvidenceResult {
  const EncryptedEvidenceResult({
    required this.cipherPath,
    required this.plaintextHash,
    required this.wrappedKeyB64,
    required this.signatureB64,
    required this.encryptedAt,
    required this.guardianShares,
    required this.nextShareX,
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

  /// One Shamir share of the incident key per guardian, each sealed to that
  /// guardian's X25519 key, keyed by guardian node ID. No single share can
  /// decrypt; [EvidenceEncryptor.guardianQuorum] of them are needed.
  final Map<String, String> guardianShares;

  /// The share index to give the next guardian issued a share for this
  /// incident (indices must never repeat).
  final int nextShareX;
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

    final guardianShares = <String, String>{};
    var nextShareX = 1;
    for (final guardian in guardians) {
      guardianShares[guardian.nodeId] = await _sealShareForGuardian(
        incidentKey,
        nextShareX++,
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
      guardianShares: guardianShares,
      nextShareX: nextShareX,
    );
  }

  /// Issues a share for a guardian paired after the incident was recorded.
  /// Shares come from a polynomial derived deterministically from the
  /// incident key, so a late share combines with ones issued at record time.
  static Future<String> issueGuardianShare({
    required String wrappedKeyB64,
    required int x,
    required String guardianX25519PublicKeyB64,
  }) async {
    final incidentKey = await unwrapIncidentKey(wrappedKeyB64);
    return _sealShareForGuardian(incidentKey, x, guardianX25519PublicKeyB64);
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

  /// Number of guardian shares needed to rebuild an incident key, so no
  /// single guardian (who could be the attacker) can view a clip alone.
  static const int guardianQuorum = 2;

  static Future<List<Uint8List>> _shareCoefficients(SecretKey incidentKey) async {
    final keyLength = (await incidentKey.extractBytes()).length;
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: keyLength * (guardianQuorum - 1),
    );
    final derived = await (await hkdf.deriveKey(
      secretKey: incidentKey,
      info: utf8.encode('justice-chain-shamir-coefficients-v1'),
    )).extractBytes();
    return [
      for (var i = 0; i < guardianQuorum - 1; i++)
        Uint8List.fromList(derived.sublist(i * keyLength, (i + 1) * keyLength)),
    ];
  }

  /// Seals Shamir share [x] of [incidentKey] for one guardian: X25519 key
  /// agreement with the guardian's public key, HKDF, then AES-GCM over
  /// `[x] ++ y`. The guardian unseals it with their own private key and
  /// this device's public key, never holding this device's private key.
  static Future<String> _sealShareForGuardian(
    SecretKey incidentKey,
    int x,
    String guardianX25519PublicKeyB64,
  ) async {
    final share = Shamir.shareAt(
      secret: Uint8List.fromList(await incidentKey.extractBytes()),
      coefficients: await _shareCoefficients(incidentKey),
      x: x,
    );
    return sealShare(share, guardianX25519PublicKeyB64);
  }

  /// Seals an existing share to [recipientX25519PublicKeyB64] from this
  /// device. Also used by a guardian forwarding their own share to a
  /// co-guardian to form a quorum.
  static Future<String> sealShare(
    ShamirShare share,
    String recipientX25519PublicKeyB64,
  ) async {
    final sharedKey = await _deriveGuardianSharedKey(recipientX25519PublicKeyB64);
    final sealedBox = await AesGcm.with256bits().encrypt(
      [share.x, ...share.y],
      secretKey: sharedKey,
    );
    return base64Encode(_packSecretBox(sealedBox));
  }

  /// Unseals a share produced by [_sealShareForGuardian]. Called on the
  /// guardian's device with its own keypair and the sender's public key.
  static Future<ShamirShare> unsealGuardianShare({
    required String sealedShareB64,
    required SimpleKeyPair ownX25519KeyPair,
    required String senderX25519PublicKeyB64,
  }) async {
    final sharedKey = await _deriveSharedKey(
      ownX25519KeyPair,
      senderX25519PublicKeyB64,
    );
    final bytes = await AesGcm.with256bits().decrypt(
      _unpackSecretBox(base64Decode(sealedShareB64)),
      secretKey: sharedKey,
    );
    return (x: bytes.first, y: Uint8List.fromList(bytes.sublist(1)));
  }

  /// Rebuilds the incident key from at least [guardianQuorum] unsealed shares.
  static SecretKey recoverIncidentKey(List<ShamirShare> shares) {
    if (shares.length < guardianQuorum) {
      throw StateError(
        'Need $guardianQuorum guardian shares to decrypt, got ${shares.length}.',
      );
    }
    return SecretKey(Shamir.combine(shares));
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

  /// Decrypts a `.enc` file from a guardian quorum's unsealed shares. A
  /// wrong or insufficient set of shares fails AES-GCM authentication.
  static Future<Uint8List> decryptFileWithShares({
    required String cipherPath,
    required List<ShamirShare> shares,
  }) {
    return _decryptFileWithKey(cipherPath, recoverIncidentKey(shares));
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
