import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'anchoring_service.dart';
import 'authority_service.dart';
import 'evidence_encryptor.dart';
import 'identity_service.dart';

/// Restoring a lost phone from its recovery code (decision doc 08-10-2026,
/// option 1). The code rebuilds the identity; the ledger lists the clips
/// that identity anchored (including clips a guardian relayed and anchored
/// on its behalf); each clip is fetched from IPFS and opened with the key
/// the code gives. No guardian is needed.
class RecoveryService {
  RecoveryService._();

  /// Status of a vault record that came back from the ledger: it has a CID
  /// and a hash but no local file or wrapped key.
  static const restoredStatus = 'restored';

  static Box get _vault => Hive.box('vault_box');

  /// Test seam: the HTTP client used to fetch clips from IPFS.
  @visibleForTesting
  static http.Client? clientForTest;

  /// Restores this phone from [code], registers [name] and [pin], and lists
  /// the identity's clips from the ledger. Returns how many were found.
  /// Throws [FormatException] for a mistyped code.
  static Future<int> restore({required String code, required String name, required String pin}) async {
    await IdentityService.restoreFromRecoveryCode(code: code, name: name, pin: pin);
    // The phone has no guardian list yet; don't let it wipe the one on the
    // ledger before the user has paired their guardians again.
    await AuthorityService.pauseGuardianSyncUntilNewGuardian();
    return restoreEvidenceList();
  }

  /// Adds every clip the ledger holds for this identity to "My Evidence".
  /// Safe to repeat; clips already listed are skipped.
  static Future<int> restoreEvidenceList() async {
    final me = await IdentityService.getMyNodeId();
    final hashes = await AnchoringService.getEvidenceHistory(me);
    if (hashes == null) throw StateError('The ledger could not be reached. Try again when online.');

    var added = 0;
    for (final hash in hashes) {
      if (_vault.containsKey(hash)) continue;
      final anchor = await AnchoringService.verifyEvidence(hash);
      if (anchor == null || !anchor.found || anchor.cid.isEmpty) continue;
      await _vault.put(hash, {
        'hash': hash,
        'cid': anchor.cid,
        'status': restoredStatus,
        'timestamp': anchor.capturedAt.toIso8601String(),
        'restoredAt': DateTime.now().toIso8601String(),
      });
      added++;
    }
    developer.log('Restored $added of ${hashes.length} clips from the ledger.', name: 'JusticeChain.Recovery');
    return added;
  }

  /// Downloads a restored clip from IPFS and decrypts it; the result is
  /// checked against the hash on the ledger.
  static Future<Uint8List> openRestoredClip(String hash) async {
    final record = _vault.get(hash);
    final cid = record is Map ? record['cid'] as String? : null;
    if (cid == null) throw StateError('No IPFS address for this clip');

    final gateway = (dotenv.isInitialized ? dotenv.env['IPFS_GATEWAY'] : null) ?? 'https://gateway.pinata.cloud/ipfs/';
    final client = clientForTest ?? http.Client();
    final response = await client.get(Uri.parse('$gateway$cid')).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw StateError('IPFS download failed (HTTP ${response.statusCode})');
    return EvidenceEncryptor.decryptWithRecoveredKey(response.bodyBytes, hash);
  }
}
