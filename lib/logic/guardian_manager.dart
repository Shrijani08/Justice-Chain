import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as developer;

import '../core/evidence_vault_service.dart';
import '../core/outbox_service.dart';

class GuardianManager {
  static final Box _box = Hive.box('vault_box');
  static const String _guardiansKey = 'trusted_guardians';

  /// Saves a verified Guardian to the local Hive Vault.
  /// [x25519PublicKey] is optional so a guardian paired before encryption
  /// key sharing existed keeps working for the mesh whitelist; it just
  /// can't receive wrapped evidence keys until it re-pairs.
  static Future<void> addGuardian({
    required String nodeId,
    required String publicKey,
    required String name,
    String? x25519PublicKey,
    String? anchoringAddress,
  }) async {
    // Fetch existing map or create a new one if empty
    Map guardians = _box.get(_guardiansKey, defaultValue: {});

    guardians[nodeId] = {
      'name': name,
      'public_key': publicKey,
      'x25519_public_key': x25519PublicKey,
      'anchoring_address': anchoringAddress,
      'added_at': DateTime.now().toIso8601String(),
    };

    await _box.put(_guardiansKey, guardians);
    developer.log('🛡️ Guardian $name ($nodeId) saved securely.', name: 'JusticeChain.Guardian');

    // Catch the new guardian up: key shares for earlier incidents, and
    // relays of any clips not yet safely anchored.
    try {
      if (x25519PublicKey != null) {
        await EvidenceVaultService.issueMissingGuardianShares();
      }
      await EvidenceVaultService.resumePendingWork();
      unawaited(OutboxService.process());
    } catch (e) {
      developer.log('Catching up new guardian failed', error: e, name: 'JusticeChain.Guardian');
    }
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