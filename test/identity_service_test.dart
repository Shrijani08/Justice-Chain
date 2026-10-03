import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Fresh in-memory secure storage for every test so registration state
    // (and IdentityService's node-id cache) never leaks between cases.
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
  });

  group('PIN hashing', () {
    test('registerNode stores an Argon2id hash, not a plain SHA-256 digest', () async {
      await IdentityService.registerNode(name: 'Test Node', pin: '123456');

      const storage = FlutterSecureStorage();
      final storedHash = await storage.read(key: 'node_pin_hash');
      final storedSalt = await storage.read(key: 'node_pin_salt');

      expect(storedHash, isNotNull);
      expect(storedSalt, isNotNull);

      final plainSha256 = crypto.sha256.convert('123456'.codeUnits).toString();
      expect(
        storedHash,
        isNot(equals(plainSha256)),
        reason: 'PIN must not be hashed with unsalted SHA-256',
      );
    });

    test('registerNode salts each registration differently', () async {
      await IdentityService.registerNode(name: 'A', pin: '123456');
      const storage = FlutterSecureStorage();
      final firstSalt = await storage.read(key: 'node_pin_salt');
      final firstHash = await storage.read(key: 'node_pin_hash');

      FlutterSecureStorage.setMockInitialValues({});
      IdentityService.resetCacheForTest();

      await IdentityService.registerNode(name: 'A', pin: '123456');
      final secondSalt = await storage.read(key: 'node_pin_salt');
      final secondHash = await storage.read(key: 'node_pin_hash');

      expect(firstSalt, isNot(equals(secondSalt)));
      expect(firstHash, isNot(equals(secondHash)));
    });

    test('verifyPin accepts the correct PIN', () async {
      await IdentityService.registerNode(name: 'Test Node', pin: '4321');

      expect(await IdentityService.verifyPin('4321'), isTrue);
    });

    test('verifyPin rejects an incorrect PIN', () async {
      await IdentityService.registerNode(name: 'Test Node', pin: '4321');

      expect(await IdentityService.verifyPin('0000'), isFalse);
    });

    test('verifyPin returns false when nothing is registered yet', () async {
      expect(await IdentityService.verifyPin('4321'), isFalse);
    });
  });

  group('registration state', () {
    test('isRegistered is false before registerNode is called', () async {
      expect(await IdentityService.isRegistered(), isFalse);
    });

    test('isRegistered is true after registerNode is called', () async {
      await IdentityService.registerNode(name: 'Test Node', pin: '4321');

      expect(await IdentityService.isRegistered(), isTrue);
    });
  });

  group('X25519 encryption key', () {
    test('initializeDevice generates an X25519 key for a fresh device', () async {
      await IdentityService.initializeDevice();

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'x25519_private_key'), isNotNull);
      expect(await storage.read(key: 'raw_x25519_public_key'), isNotNull);
    });

    test('getX25519KeyPair returns the same key across calls', () async {
      await IdentityService.initializeDevice();

      final first = await IdentityService.getX25519KeyPair();
      final second = await IdentityService.getX25519KeyPair();

      expect(
        await first.extractPrivateKeyBytes(),
        await second.extractPrivateKeyBytes(),
      );
    });

    test('getQrPayload includes the X25519 public key', () async {
      await IdentityService.initializeDevice();

      final payload = await IdentityService.getQrPayload();

      expect(payload, contains('x25519_public_key'));
    });

    test(
      'migration: a device with an existing Ed25519 identity but no X25519 '
      'key gets one generated without disturbing the Ed25519 identity',
      () async {
        // Simulate a device registered before X25519 key sharing existed:
        // seed only the Ed25519/registration keys, no x25519_private_key.
        await IdentityService.initializeDevice();
        const storage = FlutterSecureStorage();
        final originalPrivateKey = await storage.read(key: 'private_key');
        final originalNodeId = await storage.read(key: 'public_node_id');
        await storage.delete(key: 'x25519_private_key');
        await storage.delete(key: 'raw_x25519_public_key');
        IdentityService.resetCacheForTest();

        expect(await storage.read(key: 'x25519_private_key'), isNull);

        await IdentityService.initializeDevice();

        expect(await storage.read(key: 'x25519_private_key'), isNotNull);
        expect(await storage.read(key: 'raw_x25519_public_key'), isNotNull);
        // The existing Ed25519 identity must be untouched by the migration.
        expect(await storage.read(key: 'private_key'), originalPrivateKey);
        expect(await storage.read(key: 'public_node_id'), originalNodeId);
      },
    );
  });

  group('secp256k1 anchoring key', () {
    test('initializeDevice generates an anchoring key for a fresh device', () async {
      await IdentityService.initializeDevice();

      const storage = FlutterSecureStorage();
      final stored = await storage.read(key: 'anchoring_private_key');
      expect(stored, isNotNull);
      expect(stored, startsWith('0x'));
      // 32 raw bytes = 64 hex chars, plus the 0x prefix.
      expect(stored!.length, 66);
    });

    test('getAnchoringCredentials returns the same key across calls', () async {
      await IdentityService.initializeDevice();

      final first = await IdentityService.getAnchoringCredentials();
      final second = await IdentityService.getAnchoringCredentials();

      expect(first.privateKey, second.privateKey);
      expect(first.address, second.address);
    });

    test('getQrPayload includes a checksummed anchoring address', () async {
      await IdentityService.initializeDevice();

      final payload = await IdentityService.getQrPayload();
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['anchoring_address'], isNotNull);
      expect(decoded['anchoring_address'], startsWith('0x'));
      expect((decoded['anchoring_address'] as String).length, 42);

      final credentials = await IdentityService.getAnchoringCredentials();
      expect(decoded['anchoring_address'], credentials.address.eip55With0x);
    });
  });
}
