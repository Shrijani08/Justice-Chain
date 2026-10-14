import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as developer;

import '../core/authority_service.dart';
import '../core/evidence_vault_service.dart';
import '../core/mesh_service.dart';
import '../core/outbox_service.dart';

/// Paired contacts. Pairing is mutual, so each entry is both someone who
/// holds this phone's key pieces and someone whose relayed clips this phone
/// accepts when acting as their guardian.
class GuardianManager {
  static Box get _box => Hive.box('vault_box');
  static const String _guardiansKey = 'trusted_guardians';
  static const String allowSingleGuardianKey = 'allow_single_guardian';

  /// Opt-in: while fewer than two guardians can hold key pieces, new
  /// recordings can be opened by any one guardian. Off by default.
  static bool get allowSingleGuardian =>
      _box.get(allowSingleGuardianKey, defaultValue: false) as bool;

  static Future<void> setAllowSingleGuardian(bool allow) async {
    await _box.put(allowSingleGuardianKey, allow);
    developer.log('Single-guardian mode ${allow ? 'on' : 'off'}.', name: 'JusticeChain.Guardian');
  }

  /// Every contact ever paired, including removed ones. Removed contacts are
  /// kept so evidence already held from them can still be verified against
  /// the keys saved at pairing. Write paths must use this, never the
  /// filtered view, or removed contacts' keys would be lost.
  static Map _allContacts() => _box.get(_guardiansKey, defaultValue: {});

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
    // Fetch existing map or create a new one if empty. Re-pairing a removed
    // contact replaces the entry, which also clears its removal.
    Map guardians = _allContacts();

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
      await AuthorityService.resumeGuardianSync();
      await AuthorityService.requestGuardianSync();
      unawaited(OutboxService.process());
    } catch (e) {
      developer.log('Catching up new guardian failed', error: e, name: 'JusticeChain.Guardian');
    }
  }

  /// Returns all trusted guardians (removed ones excluded).
  static Map getTrustedGuardians() {
    return {
      for (final entry in _allContacts().entries)
        if (entry.value is Map && entry.value['removed_at'] == null) entry.key: entry.value,
    };
  }

  /// Like [getTrustedGuardians] but including removed contacts. Use only to
  /// verify evidence already held from someone, never to trust or share.
  static Map getAllContacts() => _allContacts();

  /// Validates if an incoming Node ID is allowed to connect
  static bool isTrusted(String nodeId) {
    final guardians = getTrustedGuardians();
    return guardians.containsKey(nodeId);
  }

  /// Changes the name shown on this phone only.
  static Future<void> renameGuardian(String nodeId, String name) async {
    final guardians = _allContacts();
    final entry = guardians[nodeId];
    if (entry is! Map || name.trim().isEmpty) return;
    guardians[nodeId] = Map<String, dynamic>.from(entry)..['name'] = name.trim();
    await _box.put(_guardiansKey, guardians);
    developer.log('✏️ Guardian $nodeId renamed to ${name.trim()}.', name: 'JusticeChain.Guardian');
  }

  /// Stops trusting [nodeId]: no new key pieces or relays go to them, their
  /// queued deliveries are cancelled, and their relays are no longer
  /// accepted. Key pieces they already received can't be taken back.
  static Future<void> removeGuardian(String nodeId) async {
    final guardians = _allContacts();
    final entry = guardians[nodeId];
    if (entry is! Map) return;
    guardians[nodeId] = Map<String, dynamic>.from(entry)
      ..['removed_at'] = DateTime.now().toIso8601String();
    await _box.put(_guardiansKey, guardians);

    final cancelled = await OutboxService.cancelJobsForNode(nodeId);
    // They must also stop being able to release this phone's key pieces.
    await AuthorityService.requestGuardianSync();
    try {
      await MeshService.disconnectNode(nodeId);
    } catch (e) {
      developer.log('Mesh disconnect on removal failed', error: e, name: 'JusticeChain.Guardian');
    }
    developer.log(
      '🗑️ Guardian ${entry['name']} ($nodeId) removed; $cancelled queued deliveries cancelled.',
      name: 'JusticeChain.Guardian',
    );
  }
}
