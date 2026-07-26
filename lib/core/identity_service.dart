import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:developer' as developer;

class IdentityService {
  IdentityService._();

  // Enforces hardware keystore on Android
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String? _cachedNodeId;

  /// Initializes the device identity.
  /// Generates an Ed25519 Keypair if one does not already exist.
  static Future<void> initializeDevice() async {
    try {
      final hasKey = await _storage.containsKey(key: 'private_key');

      if (!hasKey) {
        developer.log(
          'Generating new hardware-backed Ed25519 identity...',
          name: 'JusticeChain.Identity',
        );

        // 1. Generate a new Ed25519 Keypair
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();

        // 2. Extract raw bytes safely
        final privateBytes = await keyPair.extractPrivateKeyBytes();
        final publicBytes = (await keyPair.extractPublicKey()).bytes;

        // 3. Lock Private Key in Hardware Keystore
        await _storage.write(
          key: 'private_key',
          value: base64Encode(privateBytes),
        );

        // 4. Create Node ID (SHA-256 Hash of Public Key for a shorter 16-char string)
        final nodeId = sha256.convert(publicBytes).toString().substring(0, 16);
        await _storage.write(key: 'public_node_id', value: nodeId);

        // 5. Store the raw public key to share with Guardians
        await _storage.write(
          key: 'raw_public_key',
          value: base64Encode(publicBytes),
        );

        developer.log(
          'Identity generated successfully. Node ID: $nodeId',
          name: 'JusticeChain.Identity',
        );
      } else {
        developer.log(
          'Existing hardware identity found.',
          name: 'JusticeChain.Identity',
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
    
    return jsonEncode({
      'node_id': nodeId,
      'public_key': rawKey,
    });
  }
}
