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
import 'pinata_service.dart';

/// Moves a freshly recorded clip into the permanent vault, hashes it,
/// records it in Hive, and kicks off the IPFS upload.
///
/// This is deliberately a static service with no ties to any widget's
/// lifecycle: it is called both from a manual stop and from
/// EmergencyController's automatic recording timeout, and it must keep
/// running even if the screen that started the recording has since been
/// disposed or the screen is locked.
class EvidenceVaultService {
  EvidenceVaultService._();

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

  static Future<void> _secureEvidence(String filePath) async {
    try {
      appStatus.value = "Encrypting Evidence...";

      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception("Target evidence file does not exist.");
      }

      // Guardians paired before X25519 key sharing existed have no usable
      // key yet (migration case) and are skipped until they re-pair.
      final guardians = GuardianManager.getTrustedGuardians();
      final guardianKeys = <GuardianKeyInfo>[
        for (final entry in guardians.entries)
          if (entry.value is Map && entry.value['x25519_public_key'] != null)
            (
              nodeId: entry.key as String,
              x25519PublicKeyB64: entry.value['x25519_public_key'] as String,
            ),
      ];

      // Encrypts the clip with a random per-incident key, wraps that key to
      // this device AND to every currently-paired guardian, signs the
      // plaintext hash, and deletes the plaintext — only the ciphertext and
      // its record exist on disk from this point on.
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        filePath,
        guardians: guardianKeys,
      );

      final vaultBox = Hive.isBoxOpen('vault_box')
          ? Hive.box('vault_box')
          : await Hive.openBox('vault_box');

      // Keyed by content hash, not by insertion position, so the record
      // stays addressable even if other entries are added or removed.
      await vaultBox.put(sealed.plaintextHash, {
        'path': sealed.cipherPath,
        'hash': sealed.plaintextHash,
        'wrappedKey': sealed.wrappedKeyB64,
        'signature': sealed.signatureB64,
        'guardianWrappedKeys': sealed.guardianWrappedKeys,
        'timestamp': sealed.encryptedAt.toIso8601String(),
        'status': 'locally_secured',
        'cid': null,
      });

      developer.log(
        'Evidence encrypted and sealed: ${sealed.cipherPath}',
        name: 'JusticeChain.Vault',
      );
      appStatus.value = "Evidence Secured locally. Uploading to IPFS...";

      // Trigger automatic background upload of the ciphertext to IPFS
      unawaited(
        _uploadToIpfsInBackground(
          sealed.cipherPath,
          sealed.plaintextHash,
          vaultBox,
        ),
      );
    } catch (e) {
      developer.log(
        'Securing evidence failed',
        error: e,
        name: 'JusticeChain.Vault',
      );
      appStatus.value = "Security Error: Encryption Failed";
    }
  }

  static Future<void> _uploadToIpfsInBackground(
    String filePath,
    String entryKey,
    Box vaultBox,
  ) async {
    try {
      developer.log(
        'Initiating automatic IPFS upload for recorded video: $filePath',
        name: 'JusticeChain.Vault',
      );

      final cid = await PinataService.uploadToIPFS(filePath);

      if (cid != null && cid.isNotEmpty) {
        developer.log(
          'Automatic IPFS upload successful. CID: $cid',
          name: 'JusticeChain.Vault',
        );

        final rawData = vaultBox.get(entryKey) as Map;
        final updatedData = Map<String, dynamic>.from(rawData);
        updatedData['cid'] = cid;
        updatedData['status'] = 'uploaded_to_ipfs';
        await vaultBox.put(entryKey, updatedData);

        appStatus.value = "Evidence Secured & Uploaded to IPFS!";

        // Anchoring is additive proof on top of an already-safe upload: a
        // failure here (chain unreachable, misconfigured .env, etc.) must
        // never undo or re-flag the upload above as unsuccessful.
        final capturedAt =
            DateTime.tryParse(updatedData['timestamp'] as String? ?? '') ??
            DateTime.now();
        final nodeId = await IdentityService.getMyNodeId();
        final txHash = await AnchoringService.recordAnchor(
          manifestHashHex: entryKey,
          cid: cid,
          capturedAt: capturedAt,
          nodeId: nodeId,
        );

        if (txHash != null) {
          final anchoredData = Map<String, dynamic>.from(updatedData);
          anchoredData['anchorTxHash'] = txHash;
          anchoredData['status'] = 'anchored';
          await vaultBox.put(entryKey, anchoredData);
          appStatus.value = "Evidence Secured, Uploaded & Anchored!";
        }
      } else {
        developer.log(
          'Automatic IPFS upload failed. Evidence remains secured in local vault.',
          name: 'JusticeChain.Vault',
        );
        appStatus.value = "Evidence Secured in JusticeChain Vault";
      }
    } catch (e) {
      developer.log(
        'Error during automatic IPFS upload',
        error: e,
        name: 'JusticeChain.Vault',
      );
    }
  }
}
