import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:developer' as developer;

import '../logic/guardian_manager.dart';
import '../logic/safety_signals.dart';
import 'anchoring_service.dart';
import 'authority_service.dart';
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

  /// How many guardians a new recording needs: one only when the user has
  /// opted into single-guardian mode and has fewer than the default number
  /// of guardians that can hold key pieces.
  static int thresholdFor(int guardiansWithKeys) =>
      GuardianManager.allowSingleGuardian &&
              guardiansWithKeys < EvidenceEncryptor.guardianQuorum
          ? 1
          : EvidenceEncryptor.guardianQuorum;

  /// The threshold a record was sealed with. Records from before thresholds
  /// were stored always used the default.
  static int recordThreshold(Map record) =>
      (record['threshold'] as int?) ?? EvidenceEncryptor.guardianQuorum;

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
      final guardians = _guardiansWithKeys();
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        filePath,
        guardians: guardians,
        threshold: thresholdFor(guardians.length),
      );

      // Demo builds: the authority this recording will give a key piece to,
      // fixed now like the threshold. Never for single-guardian recordings,
      // where one piece alone would open the clip.
      final authorityMsp = sealed.threshold >= EvidenceEncryptor.guardianQuorum
          ? AuthorityService.authorityForNewRecordings()
          : null;

      // Keyed by content hash, not by insertion position, so the record
      // stays addressable even if other entries are added or removed.
      await _vaultBox.put(sealed.plaintextHash, {
        if (authorityMsp != null) 'authorityMsp': authorityMsp,
        'path': sealed.cipherPath,
        'hash': sealed.plaintextHash,
        'wrappedKey': sealed.wrappedKeyB64,
        'signature': sealed.signatureB64,
        'guardianShares': sealed.guardianShares,
        'nextShareX': sealed.nextShareX,
        'threshold': sealed.threshold,
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

    // Someone else (a relaying guardian, say) may have anchored the clip
    // first under their own key. Only this phone's own signature counts, so
    // anchor anyway: the ledger keeps it as a claim beside the first record.
    final myAddress = (await IdentityService.getAnchoringCredentials()).address.eip55With0x;
    if (existing.found && existing.signer.toLowerCase() != myAddress.toLowerCase()) {
      record['anchorConflict'] = existing.signer;
    }

    String? txHash;
    if (existing.bySigner(myAddress) == null) {
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
    await _dropLocalCopy(recordKey);

    if (record['authorityMsp'] != null && record['authorityShare'] == null) {
      await OutboxService.enqueueAuthorityShare(recordKey);
    }
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
          threshold: recordThreshold(record),
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

  /// Test seam for the IPFS download in [openOwnClip].
  @visibleForTesting
  static http.Client? clientForTest;

  /// Deletes the phone's encrypted copy of a clip once it is on IPFS and
  /// anchored: the copies there are the evidence, and a clip kept on the
  /// phone costs storage and is one more thing someone holding the phone
  /// could open. The record and its wrapped key stay, so the clip still
  /// plays (downloaded, [openOwnClip]) and guardians still get late pieces.
  /// Nearby relays need no file by then (MeshService.relayClip skips
  /// anchored clips); guardians download from IPFS instead.
  static Future<void> _dropLocalCopy(String recordKey) async {
    final raw = _vaultBox.get(recordKey);
    if (raw is! Map || raw['status'] != 'anchored' || raw['cid'] == null) return;
    final record = Map<String, dynamic>.from(raw);
    final path = record['path'] as String?;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    if (record['localCopyDeleted'] != true) {
      record['localCopyDeleted'] = true;
      await _vaultBox.put(recordKey, record);
    }
  }

  /// One of this phone's own clips, decrypted: from the local copy while it
  /// exists, else downloaded from IPFS. Throws if the clip doesn't match its
  /// hash, so the player can say it is unchanged.
  static Future<Uint8List> openOwnClip(String recordKey) async {
    final raw = _vaultBox.get(recordKey);
    if (raw is Map && raw['wrappedKey'] == null && raw['ownerKey'] != null) return _openDeviceClip(recordKey, raw);
    if (raw is! Map || raw['wrappedKey'] == null) throw StateError('No such clip on this phone');
    final wrappedKey = raw['wrappedKey'] as String;
    final path = raw['path'] as String?;
    final plaintext = path != null && await File(path).exists()
        ? await EvidenceEncryptor.decryptFile(path, wrappedKey)
        : await EvidenceEncryptor.decryptBytes(await _download(raw['cid'] as String?), wrappedKey);
    if (crypto.sha256.convert(plaintext).toString() != recordKey) {
      throw StateError('The clip does not match its record');
    }
    return plaintext;
  }

  static Future<Uint8List> _download(String? cid) async {
    if (cid == null) throw StateError('This clip has no local copy and no IPFS address yet');
    final gateway = (dotenv.isInitialized ? dotenv.env['IPFS_GATEWAY'] : null) ?? 'https://gateway.pinata.cloud/ipfs/';
    final client = clientForTest ?? http.Client();
    final response = await client.get(Uri.parse('$gateway$cid')).timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) throw StateError('Downloading the clip failed (HTTP ${response.statusCode})');
    return response.bodyBytes;
  }

  /// Saves a clip this user's SOS device recorded, from the key the device
  /// sealed for her ([sealedKey], a share with x = 0 whose y is the whole
  /// key). Checked by the caller; it lists in My evidence beside her phone's
  /// own clips and plays from IPFS ([openOwnClip]).
  static Future<void> saveDeviceClip({
    required String manifestHash,
    required String sealedKey,
    required Map certificate,
    required Map share,
    int? blockNumber,
  }) async {
    final existing = _vaultBox.get(manifestHash);
    if (existing is Map && existing['wrappedKey'] != null) return; // never replace a phone clip
    await _vaultBox.put(manifestHash, {
      'hash': manifestHash,
      'source': 'sos-device',
      'status': 'anchored',
      'cid': share['cid'],
      'timestamp': share['capturedAt'],
      'signature': share['signature'],
      'ownerKey': sealedKey,
      'deviceNodeId': certificate['deviceNodeId'],
      'deviceEd25519': certificate['deviceEd25519'],
      'deviceX25519': certificate['deviceX25519'],
      if (blockNumber != null) 'blockNumber': blockNumber,
      'localCopyDeleted': true,
    });
  }

  /// An SOS device clip: downloaded from IPFS, opened with the key the
  /// device sealed for this phone, then checked against its hash and the
  /// device's signature.
  static Future<Uint8List> _openDeviceClip(String recordKey, Map record) async {
    final share = await EvidenceEncryptor.unsealGuardianShare(
      sealedShareB64: record['ownerKey'] as String,
      ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
      senderX25519PublicKeyB64: record['deviceX25519'] as String,
    );
    if (share.x != 0) throw StateError('This is a guardian piece, not the owner key');

    final plaintext = await EvidenceEncryptor.decryptBytesWithKey(
      await _download(record['cid'] as String?),
      SecretKey(List<int>.from(share.y)),
    );
    if (crypto.sha256.convert(plaintext).toString() != recordKey) {
      throw StateError('The downloaded clip does not match its record');
    }
    final signed = await Ed25519().verify(
      utf8.encode(recordKey),
      signature: Signature(
        base64Decode(record['signature'] as String),
        publicKey: SimplePublicKey(base64Decode(record['deviceEd25519'] as String), type: KeyPairType.ed25519),
      ),
    );
    if (!signed) throw StateError("The SOS device's signature does not verify");
    return plaintext;
  }

  /// Re-queues uploads, anchors and guardian relays for records left
  /// unfinished by an earlier session, or for guardians paired since, and
  /// deletes local copies (own and relayed) of clips anchored before that
  /// was done at once.
  static Future<void> resumePendingWork() async {
    final guardianIds = GuardianManager.getTrustedGuardians().keys.cast<String>();

    if (Hive.isBoxOpen(MeshService.relayBoxName)) {
      for (final key in Hive.box(MeshService.relayBoxName).keys.toList()) {
        await _dropRelayCopy(key as String);
      }
    }

    for (final key in _vaultBox.keys.toList()) {
      final raw = _vaultBox.get(key);
      if (!_isOwnEvidence(raw)) continue;
      final recordKey = key as String;
      final status = (raw as Map)['status'];
      if (status == 'anchored') await _dropLocalCopy(recordKey);

      switch (status) {
        case 'locally_secured':
          await OutboxService.enqueueUpload(recordKey);
        case 'uploaded_to_ipfs':
          await OutboxService.enqueueAnchor(recordKey);
        case 'anchored':
          if (raw['authorityMsp'] != null && raw['authorityShare'] == null) {
            await OutboxService.enqueueAuthorityShare(recordKey);
          }
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

    // The victim may have anchored it themselves once back online. Any
    // other signer's anchor doesn't count: this relay carries her signature.
    final existing = await AnchoringService.verifyEvidence(manifestHash);
    if (existing == null) {
      throw StateError('Chain unreachable for anchor pre-check');
    }
    final victimContact = GuardianManager.getAllContacts()[relay['nodeId']];
    final victimAddress = victimContact is Map ? victimContact['anchoring_address'] as String? : null;
    final anchoredByVictim = victimAddress == null ? existing.found : existing.bySigner(victimAddress) != null;
    if (!anchoredByVictim) {
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
    await _dropRelayCopy(manifestHash);
  }

  /// Deletes a guardian's relayed copy of someone else's clip once it is on
  /// IPFS and anchored, as [_dropLocalCopy] does for this phone's own clips.
  /// The relay record stays, so the clip still lists; opening it downloads
  /// it (GuardianEvidenceService falls back to IPFS without a local copy).
  static Future<void> _dropRelayCopy(String manifestHash) async {
    final relayBox = Hive.box(MeshService.relayBoxName);
    final raw = relayBox.get(manifestHash);
    if (raw is! Map || raw['status'] != 'relay_anchored' || raw['cid'] == null) return;
    final relay = Map<String, dynamic>.from(raw);
    final path = relay['path'] as String?;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    if (relay['localCopyDeleted'] != true) {
      relay['localCopyDeleted'] = true;
      await relayBox.put(manifestHash, relay);
    }
  }
}
