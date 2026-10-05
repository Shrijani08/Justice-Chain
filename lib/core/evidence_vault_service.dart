import 'dart:async';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:developer' as developer;

import '../logic/guardian_manager.dart';
import '../logic/safety_signals.dart';
import 'anchoring_service.dart';
import 'evidence_encryptor.dart';
import 'identity_service.dart';
import 'mesh_service.dart';
import 'outbox_service.dart';
import 'pinata_service.dart';

/// Moves a freshly recorded clip into the permanent vault, encrypts it,
/// records it in Hive, and queues its upload, anchor and guardian
/// key-share deliveries on the [OutboxService].
///
/// This is deliberately a static service with no ties to any widget's
/// lifecycle: it is called both from a manual stop and from
/// EmergencyController's automatic recording timeout, and it must keep
/// running even if the screen that started the recording has since been
/// disposed or the screen is locked.
class EvidenceVaultService {
  EvidenceVaultService._();

  static Box get _vaultBox => Hive.box('vault_box');

  static Future<void> sealAndUpload(String tempVideoPath) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final vaultDir = Directory('${directory.path}/JusticeChain');

      if (!await vaultDir.exists()) {
        await vaultDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newPath = '${vaultDir.path}/evidence_$timestamp.mp4';

      final savedFile = await File(tempVideoPath).copy(newPath);
      await File(tempVideoPath).delete();

      developer.log(
        'Evidence saved permanently: ${savedFile.path}',
        name: 'JusticeChain.Vault',
      );

      await _secureEvidence(savedFile.path);
    } catch (e) {
      developer.log(
        'Failed to seal recorded evidence',
        error: e,
        name: 'JusticeChain.Vault',
      );
      appStatus.value = "Recording Save Failed";
    }
  }

  static List<GuardianKeyInfo> _guardiansWithKeys() {
    // Guardians paired before X25519 key sharing existed have no usable
    // key yet (migration case) and are skipped until they re-pair.
    final guardians = GuardianManager.getTrustedGuardians();
    return [
      for (final entry in guardians.entries)
        if (entry.value is Map && entry.value['x25519_public_key'] != null)
          (
            nodeId: entry.key as String,
            x25519PublicKeyB64: entry.value['x25519_public_key'] as String,
          ),
    ];
  }

  static bool _isOwnEvidence(Object? value) =>
      value is Map && value['wrappedKey'] != null && value['hash'] != null;

  static Future<void> _secureEvidence(String filePath) async {
    try {
      appStatus.value = "Encrypting Evidence...";

      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception("Target evidence file does not exist.");
      }

      // Encrypts the clip with a random per-incident key, wraps that key to
      // this device, gives every currently-paired guardian one Shamir share
      // of it, signs the plaintext hash, and deletes the plaintext — only
      // the ciphertext and its record exist on disk from this point on.
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        filePath,
        guardians: _guardiansWithKeys(),
      );

      // Keyed by content hash, not by insertion position, so the record
      // stays addressable even if other entries are added or removed.
      await _vaultBox.put(sealed.plaintextHash, {
        'path': sealed.cipherPath,
        'hash': sealed.plaintextHash,
        'wrappedKey': sealed.wrappedKeyB64,
        'signature': sealed.signatureB64,
        'guardianShares': sealed.guardianShares,
        'nextShareX': sealed.nextShareX,
        'timestamp': sealed.encryptedAt.toIso8601String(),
        'status': 'locally_secured',
        'cid': null,
      });

      developer.log(
        'Evidence encrypted and sealed: ${sealed.cipherPath}',
        name: 'JusticeChain.Vault',
      );
      appStatus.value = "Evidence Secured locally. Uploading to IPFS...";

      await OutboxService.enqueueUpload(sealed.plaintextHash);
      for (final guardianNodeId in sealed.guardianShares.keys) {
        await OutboxService.enqueueKeyShare(sealed.plaintextHash, guardianNodeId);
      }
      // Ciphertext relay needs no key, so every paired guardian qualifies.
      for (final guardianNodeId in GuardianManager.getTrustedGuardians().keys) {
        await OutboxService.enqueueMeshRelay(sealed.plaintextHash, guardianNodeId as String);
      }
      unawaited(OutboxService.process());
    } catch (e) {
      developer.log(
        'Securing evidence failed',
        error: e,
        name: 'JusticeChain.Vault',
      );
      appStatus.value = "Security Error: Encryption Failed";
    }
  }

  /// Outbox handler: uploads one record's ciphertext to IPFS. Throws on
  /// failure so the outbox retries with backoff.
  static Future<void> uploadRecord(String recordKey) async {
    final raw = _vaultBox.get(recordKey);
    if (raw is! Map) return;
    final record = Map<String, dynamic>.from(raw);
    if (record['cid'] != null) {
      await OutboxService.enqueueAnchor(recordKey);
      return;
    }

    final String cid;
    try {
      cid = await PinataService.uploadToIPFS(record['path'] as String);
    } on PinataUploadException catch (e) {
      appStatus.value = "Saved to local vault — upload failed, will retry: ${e.message}";
      rethrow;
    }

    developer.log('IPFS upload successful. CID: $cid', name: 'JusticeChain.Vault');
    record['cid'] = cid;
    record['status'] = 'uploaded_to_ipfs';
    await _vaultBox.put(recordKey, record);
    appStatus.value = "Evidence Secured & Uploaded to IPFS!";

    await OutboxService.enqueueAnchor(recordKey);
  }

  /// Outbox handler: anchors one uploaded record on-chain. Throws on
  /// failure so the outbox retries; a failed anchor never affects the
  /// already-safe upload.
  static Future<void> anchorRecord(String recordKey) async {
    final raw = _vaultBox.get(recordKey);
    if (raw is! Map) return;
    final record = Map<String, dynamic>.from(raw);
    final cid = record['cid'] as String?;
    if (cid == null || record['status'] == 'anchored') return;

    // A previous attempt may have landed on-chain before the app died; the
    // contract rejects duplicates, so check before resubmitting.
    final existing = await AnchoringService.verifyEvidence(recordKey);
    if (existing == null) {
      throw StateError('Chain unreachable for anchor pre-check');
    }

    String? txHash;
    if (!existing.found) {
      final capturedAt =
          DateTime.tryParse(record['timestamp'] as String? ?? '') ??
          DateTime.now();
      txHash = await AnchoringService.recordAnchor(
        manifestHashHex: recordKey,
        cid: cid,
        capturedAt: capturedAt,
        nodeId: await IdentityService.getMyNodeId(),
      );
      if (txHash == null) throw StateError('Anchor transaction failed');
    }

    record['status'] = 'anchored';
    if (txHash != null) record['anchorTxHash'] = txHash;
    await _vaultBox.put(recordKey, record);
    appStatus.value = "Evidence Secured, Uploaded & Anchored!";
  }

  /// Gives every guardian that has a usable key, but no share yet for a
  /// given incident, a fresh share, and queues its delivery. Covers
  /// guardians paired after a recording was made. Also strips the old
  /// pre-quorum full-key guardian wraps, which let one guardian decrypt alone.
  static Future<void> issueMissingGuardianShares() async {
    final guardians = _guardiansWithKeys();

    for (final key in _vaultBox.keys.toList()) {
      final raw = _vaultBox.get(key);
      if (!_isOwnEvidence(raw)) continue;
      final record = Map<String, dynamic>.from(raw as Map);
      final shares = Map<String, dynamic>.from(
        (record['guardianShares'] as Map?) ?? const {},
      );
      var nextShareX = (record['nextShareX'] as int?) ?? shares.length + 1;
      var changed = record.remove('guardianWrappedKeys') != null;

      for (final guardian in guardians) {
        if (shares.containsKey(guardian.nodeId)) continue;
        if (nextShareX > 255) break;
        shares[guardian.nodeId] = await EvidenceEncryptor.issueGuardianShare(
          wrappedKeyB64: record['wrappedKey'] as String,
          x: nextShareX++,
          guardianX25519PublicKeyB64: guardian.x25519PublicKeyB64,
        );
        await OutboxService.enqueueKeyShare(key as String, guardian.nodeId);
        changed = true;
      }

      if (changed) {
        record['guardianShares'] = shares;
        record['nextShareX'] = nextShareX;
        await _vaultBox.put(key, record);
      }
    }
  }

  /// Re-queues uploads, anchors and guardian relays for records left
  /// unfinished by an earlier session, or for guardians paired since.
  static Future<void> resumePendingWork() async {
    final guardianIds = GuardianManager.getTrustedGuardians().keys.cast<String>();

    for (final key in _vaultBox.keys.toList()) {
      final raw = _vaultBox.get(key);
      if (!_isOwnEvidence(raw)) continue;
      final recordKey = key as String;
      final status = (raw as Map)['status'];

      switch (status) {
        case 'locally_secured':
          await OutboxService.enqueueUpload(recordKey);
        case 'uploaded_to_ipfs':
          await OutboxService.enqueueAnchor(recordKey);
      }

      if (status != 'anchored') {
        final delivered = List<String>.from(raw['meshDeliveredTo'] as List? ?? const []);
        for (final guardianId in guardianIds) {
          if (!delivered.contains(guardianId)) {
            await OutboxService.enqueueMeshRelay(recordKey, guardianId);
          }
        }
      }
    }
  }

  /// Outbox handler on a guardian's phone: uploads a clip relayed over the
  /// mesh and anchors it with the victim's own pre-made signature, so the
  /// on-chain record names the victim's device whoever submits it.
  static Future<void> uploadRelayedClip(String manifestHash) async {
    final relayBox = Hive.box(MeshService.relayBoxName);
    final raw = relayBox.get(manifestHash);
    if (raw is! Map) return;
    final relay = Map<String, dynamic>.from(raw);
    if (relay['status'] == 'relay_anchored') return;

    var cid = relay['cid'] as String?;
    if (cid == null) {
      cid = await PinataService.uploadToIPFS(relay['path'] as String);
      relay['cid'] = cid;
      relay['status'] = 'relay_uploaded';
      await relayBox.put(manifestHash, relay);
      developer.log('Relayed clip uploaded on victim\'s behalf. CID: $cid', name: 'JusticeChain.Vault');
    }

    // The victim may have anchored it themselves once back online.
    final existing = await AnchoringService.verifyEvidence(manifestHash);
    if (existing == null) {
      throw StateError('Chain unreachable for anchor pre-check');
    }
    if (!existing.found) {
      final txHash = await AnchoringService.recordAnchor(
        manifestHashHex: manifestHash,
        cid: cid,
        capturedAt: DateTime.tryParse(relay['capturedAt'] as String? ?? '') ?? DateTime.now(),
        nodeId: relay['nodeId'] as String,
        signatureHex: relay['anchorSig'] as String,
      );
      if (txHash == null) throw StateError('Relay anchor transaction failed');
      relay['anchorTxHash'] = txHash;
    }

    relay['status'] = 'relay_anchored';
    await relayBox.put(manifestHash, relay);
    appStatus.value = "Relayed evidence uploaded & anchored for a contact";
  }
}
