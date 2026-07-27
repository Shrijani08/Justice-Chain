import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as developer;

class GuardianManager {
  static final Box _box = Hive.box('vault_box');
  static const String _guardiansKey = 'trusted_guardians';

  /// Saves a verified Guardian to the local Hive Vault
  static Future<void> addGuardian({
    required String nodeId,
    required String publicKey,
    required String name,
  }) async {
    // Fetch existing map or create a new one if empty
    Map guardians = _box.get(_guardiansKey, defaultValue: {});
    
    guardians[nodeId] = {
      'name': name,
      'public_key': publicKey,
      'added_at': DateTime.now().toIso8601String(),
    };

    await _box.put(_guardiansKey, guardians);
    developer.log('🛡️ Guardian $name ($nodeId) saved securely.', name: 'JusticeChain.Guardian');
  }

  /// Returns all trusted guardians
  static Map getTrustedGuardians() {
    return _box.get(_guardiansKey, defaultValue: {});
  }

  /// Validates if an incoming Node ID is allowed to connect
  static bool isTrusted(String nodeId) {
    final guardians = getTrustedGuardians();
    return guardians.containsKey(nodeId);
  }
}