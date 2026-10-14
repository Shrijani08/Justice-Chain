import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:web3dart/web3dart.dart';
import 'dart:developer' as developer;

import 'recovery_code.dart';

class IdentityService {
  IdentityService._();

  // Enforces hardware keystore on Android
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  static String? _cachedNodeId;

  /// Clears the in-memory node-id cache. Tests swap out secure storage
  /// between cases and need this cache cleared along with it.
  @visibleForTesting
  static void resetCacheForTest() {
    _cachedNodeId = null;
  }

  // OWASP-minimum Argon2id parameters. A 6-digit PIN hashed with plain
  // SHA-256 can be brute-forced in well under a second; Argon2id's
  // memory-hardness makes that infeasible, and the PIN check runs rarely
  // enough (registration, later unlock) that the extra cost is unnoticeable.
  static final Argon2id _pinHasher = Argon2id(
    parallelism: 1,
    memory: 19456, // 19 MiB
    iterations: 2,
    hashLength: 32,
  );

  static List<int> _generateSalt([int length = 16]) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }

  /// Initializes the device identity.
  /// A new phone gets all its keys (Ed25519 signing, X25519 encryption,
  /// secp256k1 anchoring, and the evidence root that clip keys come from)
  /// from one random recovery secret, whose code is shown once at
  /// registration. Phones set up before recovery codes keep their random
  /// keys; the X25519 and anchoring checks below still fill in keys that
  /// such a phone was created without.
  static Future<void> initializeDevice() async {
    try {
      final hasIdentityKey = await _storage.containsKey(key: 'private_key');

      if (!hasIdentityKey) {
        developer.log(
          'Generating new identity from a recovery secret...',
          name: 'JusticeChain.Identity',
        );
        final secret = RecoveryCode.newSecret();
        await _installIdentity(secret);
        // Kept only until the user confirms they wrote the code down.
        await _storage.write(key: _pendingCodeKey, value: RecoveryCode.format(secret));
      } else {
        developer.log(
          'Existing hardware identity found.',
          name: 'JusticeChain.Identity',
        );
      }

      final hasEncryptionKey = await _storage.containsKey(
        key: 'x25519_private_key',
      );

      if (!hasEncryptionKey) {
        developer.log(
          'Generating new X25519 encryption key...',
          name: 'JusticeChain.Identity',
        );

        final x25519 = X25519();
        final x25519KeyPair = await x25519.newKeyPair();
        final x25519PrivateBytes = await x25519KeyPair.extractPrivateKeyBytes();
        final x25519PublicBytes = (await x25519KeyPair.extractPublicKey()).bytes;

        await _storage.write(
          key: 'x25519_private_key',
          value: base64Encode(x25519PrivateBytes),
        );
        await _storage.write(
          key: 'raw_x25519_public_key',
          value: base64Encode(x25519PublicBytes),
        );
      }

      final hasAnchoringKey = await _storage.containsKey(
        key: 'anchoring_private_key',
      );

      if (!hasAnchoringKey) {
        developer.log(
          'Generating new secp256k1 anchoring key...',
          name: 'JusticeChain.Identity',
        );

        final anchoringKey = EthPrivateKey.createRandom(Random.secure());
        await _storage.write(
          key: 'anchoring_private_key',
          // privateKey's raw bytes are variable-length (33 bytes whenever
          // the key's high bit is set, since it's derived from a BigInt,
          // not a fixed-width buffer) — encode via the int directly, padded
          // to a canonical 32-byte hex string, so storage and EthPrivateKey
          // round-trip consistently regardless of which random key we get.
          value:
              '0x${anchoringKey.privateKeyInt.toRadixString(16).padLeft(64, '0')}',
        );
      }
    } catch (e, stackTrace) {
      developer.log(
        'Failed to initialize device identity',
        name: 'JusticeChain.Identity',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static const _pendingCodeKey = 'recovery_code_pending';
  static const _evidenceRootKey = 'evidence_root';

  /// Writes every key derived from [secret] to secure storage, replacing
  /// any identity already there.
  static Future<void> _installIdentity(List<int> secret) async {
    final keys = await RecoveryCode.deriveKeys(secret);

    final edKeyPair = await Ed25519().newKeyPairFromSeed(keys.ed25519Seed);
    final edPublic = (await edKeyPair.extractPublicKey()).bytes;
    // Node ID: the first 16 hex characters of SHA-256 of the public key.
    final nodeId = sha256.convert(edPublic).toString().substring(0, 16);

    final xKeyPair = await X25519().newKeyPairFromSeed(keys.x25519Seed);
    final xPublic = (await xKeyPair.extractPublicKey()).bytes;

    await _storage.write(key: 'private_key', value: base64Encode(keys.ed25519Seed));
    await _storage.write(key: 'public_node_id', value: nodeId);
    await _storage.write(key: 'raw_public_key', value: base64Encode(edPublic));
    await _storage.write(key: 'x25519_private_key', value: base64Encode(keys.x25519Seed));
    await _storage.write(key: 'raw_x25519_public_key', value: base64Encode(xPublic));
    await _storage.write(
      key: 'anchoring_private_key',
      value: '0x${keys.anchoringKey.toRadixString(16).padLeft(64, '0')}',
    );
    await _storage.write(key: _evidenceRootKey, value: base64Encode(keys.evidenceRoot));
    _cachedNodeId = null;
    developer.log('Identity installed. Node ID: $nodeId', name: 'JusticeChain.Identity');
  }

  /// The recovery code, until the user confirms they saved it; null after
  /// that, and on phones set up before recovery codes existed.
  static Future<String?> pendingRecoveryCode() => _storage.read(key: _pendingCodeKey);

  /// Forgets the recovery code. From now on only the user has it.
  static Future<void> confirmRecoveryCodeSaved() => _storage.delete(key: _pendingCodeKey);

  /// Whether this phone's clips can be reopened from a recovery code.
  static Future<bool> hasRecoveryCode() => _storage.containsKey(key: _evidenceRootKey);

  /// Turns this phone into the one the code belongs to: same node ID and
  /// keys, so its clips on the ledger are its own again. Throws
  /// [FormatException] for a mistyped code. Then registers [name] and [pin].
  static Future<void> restoreFromRecoveryCode({
    required String code,
    required String name,
    required String pin,
  }) async {
    final secret = RecoveryCode.parse(code);
    await _installIdentity(secret);
    await confirmRecoveryCodeSaved(); // the user already has it
    await registerNode(name: name, pin: pin);
  }

  /// The AES key for the clip whose content hash is [plaintextHashHex], or
  /// null on a phone without a recovery code (its clips use random keys).
  static Future<SecretKey?> clipKeyFor(String plaintextHashHex) async {
    final root = await _storage.read(key: _evidenceRootKey);
    if (root == null) return null;
    return RecoveryCode.clipKey(base64Decode(root), plaintextHashHex);
  }

  /// Registers the user's name and PIN, and ensures keys are initialized.
  static Future<void> registerNode({required String name, required String pin}) async {
    try {
      // 1. Hash the Vault PIN with Argon2id and a fresh random salt
      final salt = _generateSalt();
      final secretKey = await _pinHasher.deriveKeyFromPassword(
        password: pin,
        nonce: salt,
      );
      final pinHash = base64Encode(await secretKey.extractBytes());

      // 2. Persist name, salt and PIN hash to secure storage
      await _storage.write(key: 'node_name', value: name);
      await _storage.write(key: 'node_pin_salt', value: base64Encode(salt));
      await _storage.write(key: 'node_pin_hash', value: pinHash);

      // 3. Ensure Ed25519 keys are generated and stored
      await initializeDevice();

      developer.log(
        'SUCCESS: Identity established for node -> $name',
        name: 'JusticeChain.Identity',
      );
    } catch (e, stackTrace) {
      developer.log(
        'Failed to register node',
        name: 'JusticeChain.Identity',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Verifies a PIN entry against the stored Argon2id hash. Returns false
  /// (rather than throwing) if no PIN has been registered yet.
  static Future<bool> verifyPin(String pin) async {
    final storedHash = await _storage.read(key: 'node_pin_hash');
    final storedSalt = await _storage.read(key: 'node_pin_salt');
    if (storedHash == null || storedSalt == null) return false;

    final secretKey = await _pinHasher.deriveKeyFromPassword(
      password: pin,
      nonce: base64Decode(storedSalt),
    );
    final candidateHash = base64Encode(await secretKey.extractBytes());

    return _constantTimeEquals(candidateHash, storedHash);
  }

  /// Checks if a node has been registered yet
  static Future<bool> isRegistered() async {
    final name = await _storage.read(key: 'node_name');
    return name != null && name.isNotEmpty;
  }

  /// Retrieves the public Node ID to display on the screen
  static Future<String> getMyNodeId() async {
    if (_cachedNodeId != null) return _cachedNodeId!;
    _cachedNodeId = await _storage.read(key: 'public_node_id');
    return _cachedNodeId ?? "ERROR_NO_ID";
  }

  /// Generates the JSON payload to be embedded in the QR Code
  static Future<String> getQrPayload() async {
    final nodeId = await getMyNodeId();
    final rawKey = await _storage.read(key: 'raw_public_key');
    final rawX25519Key = await _storage.read(key: 'raw_x25519_public_key');

    String? anchoringAddress;
    final anchoringKeyHex = await _storage.read(key: 'anchoring_private_key');
    if (anchoringKeyHex != null) {
      anchoringAddress = EthPrivateKey.fromHex(anchoringKeyHex).address.eip55With0x;
    }

    return jsonEncode({
      'node_id': nodeId,
      'public_key': rawKey,
      'x25519_public_key': rawX25519Key,
      // Address only, per the blueprint — the anchoring key itself never
      // leaves the device; this just lets a guardian cross-check who
      // signed an on-chain record.
      'anchoring_address': anchoringAddress,
    });
  }

  /// Reconstructs this device's anchoring credentials (secp256k1) from
  /// secure storage, for signing on-chain evidence anchors.
  static Future<EthPrivateKey> getAnchoringCredentials() async {
    final privateKeyHex = await _storage.read(key: 'anchoring_private_key');
    if (privateKeyHex == null) {
      throw StateError(
        'No anchoring key found; call initializeDevice() first.',
      );
    }

    return EthPrivateKey.fromHex(privateKeyHex);
  }

  /// Reconstructs this device's X25519 keypair from secure storage, for key
  /// agreement with a guardian's public key when wrapping an incident key.
  static Future<SimpleKeyPair> getX25519KeyPair() async {
    final privateKeyB64 = await _storage.read(key: 'x25519_private_key');
    if (privateKeyB64 == null) {
      throw StateError(
        'No X25519 key found; call initializeDevice() first.',
      );
    }

    return X25519().newKeyPairFromSeed(base64Decode(privateKeyB64));
  }

  /// Returns this device's vault key-encryption-key, generating one on
  /// first use. It never leaves the device and exists only to wrap
  /// per-incident evidence keys, so only this device can ever unwrap them.
  static Future<SecretKey> getOrCreateVaultKey() async {
    final algorithm = AesGcm.with256bits();
    final existing = await _storage.read(key: 'vault_master_key');

    if (existing != null) {
      return SecretKey(base64Decode(existing));
    }

    developer.log(
      'Generating new vault key-encryption-key...',
      name: 'JusticeChain.Identity',
    );

    final key = await algorithm.newSecretKey();
    final keyBytes = await key.extractBytes();
    await _storage.write(key: 'vault_master_key', value: base64Encode(keyBytes));
    return key;
  }

  /// Signs arbitrary bytes with the device's existing Ed25519 identity key,
  /// so a court can later check that a specific device produced a hash.
  static Future<String> signBytes(List<int> bytes) async {
    final privateKeyB64 = await _storage.read(key: 'private_key');
    if (privateKeyB64 == null) {
      throw StateError('No identity key found; call initializeDevice() first.');
    }

    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(base64Decode(privateKeyB64));
    final signature = await algorithm.sign(bytes, keyPair: keyPair);
    return base64Encode(signature.bytes);
  }
}