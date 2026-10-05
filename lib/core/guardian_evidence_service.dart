import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../logic/guardian_manager.dart';
import 'anchoring_service.dart';
import 'evidence_encryptor.dart';
import 'identity_service.dart';
import 'mesh_service.dart';
import 'shamir.dart';

/// One incident a guardian holds something for: key shares, a relayed
/// ciphertext copy, or both.
class GuardianIncident {
  GuardianIncident({
    required this.manifestHash,
    required this.victimNodeId,
    required this.victimName,
    required this.capturedAt,
    required this.cid,
    required this.shareCount,
    required this.hasOwnShare,
    required this.hasLocalCopy,
  });

  final String manifestHash;
  final String victimNodeId;
  final String victimName;
  final DateTime? capturedAt;
  final String? cid;
  final int shareCount;
  final bool hasOwnShare;
  final bool hasLocalCopy;

  bool get hasQuorum => shareCount >= EvidenceEncryptor.guardianQuorum;
}

/// A single verification step's outcome. [passed] is null when the check
/// could not be run (e.g. chain unreachable), which is not a pass.
class VerificationCheck {
  const VerificationCheck(this.label, this.passed, this.detail);
  final String label;
  final bool? passed;
  final String detail;
}

class VerifiedClip {
  VerifiedClip({required this.plaintext, required this.checks, this.anchorSummary});
  final Uint8List plaintext;
  final List<VerificationCheck> checks;

  /// e.g. "Verified: anchored in block 12 at 2026-10-04 14:02".
  final String? anchorSummary;

  bool get fullyVerified => checks.every((c) => c.passed == true);
}

/// Guardian-side retrieval and verification (blueprint Phase 5): gather a
/// quorum of key shares, fetch the ciphertext (relayed copy or IPFS),
/// decrypt, then check the content hash, the victim's device signature
/// and the on-chain record before anything is played.
class GuardianEvidenceService {
  GuardianEvidenceService._();

  static Box get _sharesBox => Hive.box(MeshService.receivedSharesBoxName);
  static Box get _relayBox => Hive.box(MeshService.relayBoxName);

  static List<Map<String, dynamic>> _sharesFor(String manifestHash) => [
        for (final s in _sharesBox.values)
          if (s is Map && s['manifestHash'] == manifestHash) Map<String, dynamic>.from(s),
      ];

  static List<GuardianIncident> listIncidents() {
    final hashes = <String>{
      for (final s in _sharesBox.values)
        if (s is Map) s['manifestHash'] as String,
      ..._relayBox.keys.cast<String>(),
    };
    final contacts = GuardianManager.getTrustedGuardians();

    final incidents = [
      for (final hash in hashes) _buildIncident(hash, contacts),
    ]..sort((a, b) => (b.capturedAt ?? DateTime(0)).compareTo(a.capturedAt ?? DateTime(0)));
    return incidents;
  }

  static GuardianIncident _buildIncident(String hash, Map contacts) {
    final shares = _sharesFor(hash);
    final relayRaw = _relayBox.get(hash);
    final relay = relayRaw is Map ? Map<String, dynamic>.from(relayRaw) : null;
    final any = shares.isNotEmpty ? shares.first : relay ?? const <String, dynamic>{};

    final victimNodeId = (any['victimNodeId'] ?? any['nodeId'] ?? 'unknown') as String;
    final contact = contacts[victimNodeId];
    final cid = shares.map((s) => s['cid']).whereType<String>().firstOrNull ??
        relay?['cid'] as String?;

    return GuardianIncident(
      manifestHash: hash,
      victimNodeId: victimNodeId,
      victimName: contact is Map ? contact['name'] as String? ?? victimNodeId : victimNodeId,
      capturedAt: DateTime.tryParse((any['capturedAt'] as String?) ?? ''),
      cid: cid,
      shareCount: shares.map((s) => s['senderNodeId']).toSet().length,
      hasOwnShare: shares.any((s) => s['forwardedBy'] == null),
      hasLocalCopy: relay != null && File(relay['path'] as String).existsSync(),
    );
  }

  static Future<VerifiedClip> openAndVerify(String manifestHash) async {
    final incident = _buildIncident(manifestHash, GuardianManager.getTrustedGuardians());
    final checks = <VerificationCheck>[];

    // 1. Rebuild the incident key from a quorum of shares.
    final ownKeyPair = await IdentityService.getX25519KeyPair();
    final unsealed = <int, ShamirShare>{};
    for (final entry in _sharesFor(manifestHash)) {
      final share = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: entry['sealedShare'] as String,
        ownX25519KeyPair: ownKeyPair,
        senderX25519PublicKeyB64: entry['senderX25519'] as String,
      );
      unsealed[share.x] = share;
    }
    if (unsealed.length < EvidenceEncryptor.guardianQuorum) {
      throw StateError(
        'Need ${EvidenceEncryptor.guardianQuorum} guardian key pieces, have ${unsealed.length}. '
        'Ask another guardian to send you theirs.',
      );
    }

    // 2. Chain record (also a CID source when nothing local has it).
    final anchor = await AnchoringService.verifyEvidence(manifestHash);
    final cid = incident.cid ?? ((anchor?.found ?? false) ? anchor!.cid : null);

    // 3. Ciphertext: relayed copy first, else fetch from IPFS.
    final cipherPath = await _obtainCiphertext(manifestHash, cid);
    final plaintext = await EvidenceEncryptor.decryptFileWithShares(
      cipherPath: cipherPath,
      shares: unsealed.values.toList(),
    );
    checks.add(VerificationCheck(
      'Decrypted by guardian quorum',
      true,
      '${unsealed.length} key pieces; AES-GCM authenticated the ciphertext',
    ));

    // 4. Content hash: the plaintext must be exactly what was sealed.
    final actualHash = crypto.sha256.convert(plaintext).toString();
    checks.add(VerificationCheck(
      'Content hash matches',
      actualHash == manifestHash,
      actualHash == manifestHash ? 'SHA-256 $manifestHash' : 'expected $manifestHash, got $actualHash',
    ));

    // 5. Victim's device signature over that hash.
    checks.add(await _checkDeviceSignature(manifestHash, incident.victimNodeId));

    // 6. On-chain record and block.
    String? anchorSummary;
    if (anchor == null) {
      checks.add(const VerificationCheck('Anchored on-chain', null, 'Chain unreachable — could not check'));
    } else if (!anchor.found) {
      checks.add(const VerificationCheck('Anchored on-chain', false, 'No on-chain record for this hash yet'));
    } else {
      final cidMatches = cid == null || anchor.cid == cid;
      checks.add(VerificationCheck(
        'On-chain CID matches',
        cidMatches,
        cidMatches ? anchor.cid : 'chain has ${anchor.cid}, copy came from $cid',
      ));
      checks.add(_checkSigner(anchor.signer, incident.victimNodeId));

      final block = await AnchoringService.findAnchorBlock(manifestHash);
      final when = block?.blockTime ?? anchor.anchoredAt;
      anchorSummary = block != null
          ? 'Verified: anchored in block ${block.blockNumber} at ${_fmt(when)}'
          : 'Verified: anchored at ${_fmt(when)}';
      checks.add(VerificationCheck(
        'Anchored on-chain',
        true,
        '${anchorSummary.replaceFirst('Verified: ', '')} · device clock said ${_fmt(anchor.capturedAt)}',
      ));
    }

    return VerifiedClip(plaintext: plaintext, checks: checks, anchorSummary: anchorSummary);
  }

  static Future<String> _obtainCiphertext(String manifestHash, String? cid) async {
    final relay = _relayBox.get(manifestHash);
    if (relay is Map && File(relay['path'] as String).existsSync()) {
      return relay['path'] as String;
    }
    if (cid == null) {
      throw StateError('No local copy and no IPFS CID known for this clip yet.');
    }

    final gateway = dotenv.env['IPFS_GATEWAY'] ?? 'https://gateway.pinata.cloud/ipfs/';
    final response = await http
        .get(Uri.parse('$gateway$cid'))
        .timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) {
      throw StateError('IPFS fetch failed (HTTP ${response.statusCode}).');
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/fetched_$manifestHash.enc';
    await File(path).writeAsBytes(response.bodyBytes);
    return path;
  }

  static Future<VerificationCheck> _checkDeviceSignature(String manifestHash, String victimNodeId) async {
    const label = "Signed by the victim's device";
    final signatureB64 = _sharesFor(manifestHash)
        .map((s) => s['signature'])
        .whereType<String>()
        .firstOrNull;
    final contact = GuardianManager.getTrustedGuardians()[victimNodeId];
    final publicKeyB64 = contact is Map ? contact['public_key'] as String? : null;

    if (signatureB64 == null || publicKeyB64 == null) {
      return const VerificationCheck(label, null, 'Signature or paired device key missing');
    }

    final ok = await Ed25519().verify(
      utf8.encode(manifestHash),
      signature: Signature(
        base64Decode(signatureB64),
        publicKey: SimplePublicKey(base64Decode(publicKeyB64), type: KeyPairType.ed25519),
      ),
    );
    return VerificationCheck(label, ok, ok ? 'Ed25519 key saved at pairing' : 'Signature does not verify');
  }

  static VerificationCheck _checkSigner(String chainSigner, String victimNodeId) {
    const label = 'On-chain signer is the victim';
    final contact = GuardianManager.getTrustedGuardians()[victimNodeId];
    final expected = contact is Map ? contact['anchoring_address'] as String? : null;
    if (expected == null) {
      return VerificationCheck(label, null, 'Signer $chainSigner (no address saved at pairing to compare)');
    }
    final ok = expected.toLowerCase() == chainSigner.toLowerCase();
    return VerificationCheck(label, ok, ok ? chainSigner : 'expected $expected, chain has $chainSigner');
  }

  static String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
