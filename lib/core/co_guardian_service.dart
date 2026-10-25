import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web3dart/web3dart.dart' as web3;

import '../logic/guardian_manager.dart';
import 'authority_service.dart';
import 'device_link_service.dart';
import 'evidence_encryptor.dart';
import 'identity_service.dart';
import 'ledger/fabric_ledger_service.dart';
import 'mesh_service.dart';

/// Another guardian of the same victim, as read from the ledger and checked
/// on this phone.
class CoGuardian {
  const CoGuardian({required this.nodeId, required this.ed25519PublicKey, required this.x25519PublicKey, this.name});

  final String nodeId;
  final String ed25519PublicKey;
  final String x25519PublicKey;

  /// The name saved when this phone paired with them, or null if it never did.
  final String? name;

  /// "Riya", or "Guardian 2b50…6556" for someone this phone never paired with.
  String get label => name ?? 'Guardian ${shortNodeId(nodeId)}';
}

String shortNodeId(String id) => id.length > 8 ? '${id.substring(0, 4)}…${id.substring(id.length - 4)}' : id;

/// The ledger's answer could not be trusted, e.g. a signature that doesn't
/// check out. The gateway may be lying, so nothing is sent.
class UntrustedLedgerRecord implements Exception {
  UntrustedLedgerRecord(this.message);
  final String message;

  @override
  String toString() => 'Untrusted ledger record: $message';
}

/// Lets two guardians of the same victim combine their key pieces without
/// having paired with each other.
///
/// Who the other guardians are comes from the ledger, but this phone checks
/// every record itself rather than trusting the gateway: the victim's
/// guardian list must carry the victim's anchoring signature, and each
/// guardian's keys their own registration signature. The root of trust is
/// the victim's keys this phone saved when it paired with the victim.
///
/// Pieces travel through the gateway's mailbox, sealed to the recipient's
/// X25519 key and signed by the sender's Ed25519 key, and the ledger records
/// each forward's hash in the clip's audit trail.
class CoGuardianService {
  CoGuardianService._();

  static Box get _vault => Hive.box('vault_box');
  static const String _listSequencesKey = 'co_guardian_list_sequences';
  static const String _pendingForwardsKey = 'piece_forwards';

  static FabricLedgerService get _ledger => AuthorityService.requireGateway();

  // Checking ledger records

  /// The address that made an anchoring-key action signature over
  /// [payload], as the chaincode's recoverActionSigner: EIP-191 over the 32
  /// raw bytes of the payload's SHA-256. Null when it can't be recovered.
  @visibleForTesting
  static String? recoverActionSigner(String payload, String signatureHex) =>
      recoverHashSigner(crypto.sha256.convert(utf8.encode(payload)).toString(), signatureHex);

  /// The address that signed the 32 raw bytes of [hashHex] with EIP-191
  /// (AnchoringService.signAnchor), lowercase with 0x.
  @visibleForTesting
  static String? recoverHashSigner(String hashHex, String signatureHex) {
    try {
      final sig = web3.hexToBytes(signatureHex);
      if (sig.length != 65) return null;
      final hash = web3.hexToBytes(hashHex);
      final prefixed = Uint8List.fromList([...ascii.encode('\u0019Ethereum Signed Message:\n${hash.length}'), ...hash]);
      final publicKey = web3.ecRecover(
        web3.keccak256(prefixed),
        web3.MsgSignature(
          web3.bytesToUnsignedInt(sig.sublist(0, 32)),
          web3.bytesToUnsignedInt(sig.sublist(32, 64)),
          sig[64],
        ),
      );
      return web3.bytesToHex(web3.publicKeyToAddress(publicKey), include0x: true).toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _verifyEd25519(String publicKeyB64, String payload, String signatureB64) async {
    try {
      return await Ed25519().verify(
        utf8.encode(payload),
        signature: Signature(
          base64Decode(signatureB64),
          publicKey: SimplePublicKey(base64Decode(publicKeyB64), type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Whether a node record from the ledger holds together on its own: the ID
  /// is derived from the Ed25519 key, and that key signed the registration,
  /// which names the X25519 key and anchoring address.
  @visibleForTesting
  static Future<bool> verifyNodeRecord(Map record) async {
    final nodeId = record['nodeId'] as String?;
    final edKey = record['ed25519PublicKey'] as String?;
    final xKey = record['x25519PublicKey'] as String?;
    final address = record['anchoringAddress'] as String?;
    final signature = record['ed25519Signature'] as String?;
    if (nodeId == null || edKey == null || xKey == null || address == null || signature == null) return false;
    final List<int> edBytes;
    try {
      edBytes = base64Decode(edKey);
    } catch (_) {
      return false;
    }
    if (crypto.sha256.convert(edBytes).toString().substring(0, 16) != nodeId) return false;
    return _verifyEd25519(edKey, 'justice-chain/register-node/v1|$nodeId|$edKey|$xKey|$address', signature);
  }

  /// Checks a victim's guardian list against the victim's node record (which
  /// must itself match the keys saved at pairing) and returns the guardian
  /// IDs. Throws [UntrustedLedgerRecord] if anything doesn't check out.
  @visibleForTesting
  static Future<List<String>> verifyGuardianList({
    required Map victimRecord,
    required Map list,
    required Map pairedVictim,
    int? lastSequence,
  }) async {
    final victim = victimRecord['nodeId'] as String?;
    if (!await verifyNodeRecord(victimRecord)) {
      throw UntrustedLedgerRecord("the victim's registration doesn't check out");
    }
    if (victimRecord['ed25519PublicKey'] != pairedVictim['public_key']) {
      throw UntrustedLedgerRecord("the victim's key on the ledger isn't the one saved at pairing");
    }
    final pairedAddress = (pairedVictim['anchoring_address'] as String?)?.toLowerCase();
    final address = (victimRecord['anchoringAddress'] as String).toLowerCase();
    if (pairedAddress != null && pairedAddress != address) {
      throw UntrustedLedgerRecord("the victim's anchoring address isn't the one saved at pairing");
    }

    if (list['found'] != true || list['victimNodeId'] != victim) {
      throw UntrustedLedgerRecord('no guardian list on the ledger yet');
    }
    final ids = List<String>.from(list['guardians'] as List)..sort();
    final sequence = list['sequence'] as int;
    final signature = list['signature'] as String?;
    if (signature == null) {
      throw UntrustedLedgerRecord("the guardian list isn't signed yet; it is once the victim's app updates it");
    }
    final signer = recoverActionSigner('justice-chain/set-guardians/v1|$victim|$sequence|${ids.join(',')}', signature);
    if (signer != address) {
      throw UntrustedLedgerRecord("the guardian list isn't signed by the victim");
    }
    if (lastSequence != null && sequence < lastSequence) {
      throw UntrustedLedgerRecord('the ledger returned an older guardian list than this phone has seen');
    }
    return ids;
  }

  /// The victim's other guardians, checked on this phone. This phone must be
  /// the victim's paired guardian. Throws [UntrustedLedgerRecord] when the
  /// ledger's answer doesn't check out.
  static Future<List<CoGuardian>> coGuardiansOf(String victimNodeId) async {
    final paired = GuardianManager.getTrustedGuardians()[victimNodeId];
    if (paired is! Map) throw UntrustedLedgerRecord('this phone is not paired with $victimNodeId');
    final ledger = _ledger;

    final victimRecord = await ledger.getNode(victimNodeId);
    if (victimRecord['found'] != true) throw UntrustedLedgerRecord('the victim is not registered on the ledger');
    final sequences = Map<String, dynamic>.from(_vault.get(_listSequencesKey, defaultValue: {}) as Map);
    final list = await ledger.getGuardians(victimNodeId);
    final ids = await verifyGuardianList(
      victimRecord: victimRecord,
      list: list,
      pairedVictim: paired,
      lastSequence: sequences[victimNodeId] as int?,
    );
    sequences[victimNodeId] = list['sequence'] as int;
    await _vault.put(_listSequencesKey, sequences);

    final me = await IdentityService.getMyNodeId();
    final contacts = GuardianManager.getTrustedGuardians();
    final result = <CoGuardian>[];
    for (final id in ids) {
      if (id == me) continue;
      final record = await ledger.getNode(id);
      if (record['found'] != true || !await verifyNodeRecord(record)) {
        developer.log("Skipping guardian $id: registration doesn't check out", name: 'JusticeChain.CoGuardian');
        continue;
      }
      final contact = contacts[id];
      result.add(CoGuardian(
        nodeId: id,
        ed25519PublicKey: record['ed25519PublicKey'] as String,
        x25519PublicKey: record['x25519PublicKey'] as String,
        name: contact is Map ? contact['name'] as String? : null,
      ));
    }
    return result;
  }

  // Sending a piece

  /// The payload a guardian signs with Ed25519 to forward a piece (the
  /// chaincode's ForwardPiece checks the same text).
  @visibleForTesting
  static String forwardPayload(String manifestHash, String victim, String from, String to, String pieceHash) =>
      'justice-chain/forward-piece/v1|$manifestHash|$victim|$from|$to|$pieceHash';

  /// The outbox job: re-seals this phone's own piece of [manifestHash] to
  /// co-guardian [toNodeId] and posts it to the gateway's mailbox. The
  /// sealed piece is kept until the post succeeds, so a retry sends the
  /// same piece and the ledger records it once. Returns false when this
  /// phone holds no piece of its own for the clip, so there is nothing to send.
  static Future<bool> forwardViaMailbox(String manifestHash, String toNodeId) async {
    final own = Hive.box(MeshService.receivedSharesBoxName)
        .values
        .whereType<Map>()
        .where((s) => s['manifestHash'] == manifestHash && s['forwardedBy'] == null)
        .firstOrNull;
    if (own == null) return false;
    final victim = own['victimNodeId'] as String;
    final me = await IdentityService.getMyNodeId();

    final pendingAll = Map<String, dynamic>.from(_vault.get(_pendingForwardsKey, defaultValue: {}) as Map);
    final pendingKey = '$manifestHash:$toNodeId';
    var sealed = (pendingAll[pendingKey] as Map?)?['sealedShare'] as String?;
    if (sealed == null) {
      final recipient = (await coGuardiansOf(victim)).where((g) => g.nodeId == toNodeId).firstOrNull;
      if (recipient == null) throw StateError('$toNodeId is not on the victim\'s guardian list');
      final piece = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: own['sealedShare'] as String,
        ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
        senderX25519PublicKeyB64: own['senderX25519'] as String,
      );
      sealed = await EvidenceEncryptor.sealShare(piece, recipient.x25519PublicKey);
      pendingAll[pendingKey] = {'sealedShare': sealed};
      await _vault.put(_pendingForwardsKey, pendingAll);
    }

    final pieceHash = crypto.sha256.convert(base64Decode(sealed)).toString();
    final myX25519 = base64Encode((await (await IdentityService.getX25519KeyPair()).extractPublicKey()).bytes);
    // What the recipient needs besides the piece: the clip's details and the
    // victim's own signature over it, exactly as the victim sent them.
    final share = Map<String, dynamic>.from(own)
      ..remove('receivedAt')
      ..remove('sealedShare')
      ..remove('senderNodeId')
      ..remove('senderX25519')
      ..remove('forwardedBy');

    await _ledger.forwardPiece({
      'manifestHash': manifestHash,
      'victimNodeId': victim,
      'fromNodeId': me,
      'toNodeId': toNodeId,
      'sealedShare': sealed,
      'senderX25519': myX25519,
      'signature': await IdentityService.signBytes(utf8.encode(forwardPayload(manifestHash, victim, me, toNodeId, pieceHash))),
      'share': share,
    });

    pendingAll[pendingKey] = {'sentAt': DateTime.now().toIso8601String()};
    await _vault.put(_pendingForwardsKey, pendingAll);
    developer.log('Forwarded my piece of $manifestHash to $toNodeId via the mailbox', name: 'JusticeChain.CoGuardian');
    return true;
  }

  /// True once the user chose to send their piece of [manifestHash] to [toNodeId].
  static bool forwardSent(String manifestHash, String toNodeId) =>
      (_vault.get(_pendingForwardsKey) as Map?)?['$manifestHash:$toNodeId'] is Map;

  // Receiving pieces

  /// Fetches pieces co-guardians sent this phone, checks each against the
  /// ledger, stores the good ones as forwarded pieces and clears them from
  /// the mailbox. Returns how many were stored. Pieces that fail a check are
  /// cleared too, so they aren't fetched forever; ones that couldn't be
  /// checked (offline) stay for next time.
  static Future<int> fetchMailbox() async {
    if (!AuthorityService.ledgerFeaturesEnabled) return 0;
    final ledger = _ledger;
    final me = await IdentityService.getMyNodeId();
    final envelopes = await ledger.listPieces(me);
    if (envelopes.isEmpty) return 0;

    final directories = <String, List<CoGuardian>>{};
    final done = <String>[];
    var stored = 0;
    for (final env in envelopes) {
      final id = env['id'] as String;
      try {
        if (env['kind'] == 'device') {
          // Null: from someone this phone hasn't paired with yet, so it can't
          // be checked; it stays in the mailbox until they pair.
          final kept = await _storeDevicePiece(env, me);
          if (kept != null) {
            stored += kept;
            done.add(id);
          }
          continue;
        }
        final victim = env['victimNodeId'] as String;
        final from = env['fromNodeId'] as String;
        final hash = env['manifestHash'] as String;
        final sealed = env['sealedShare'] as String;
        final coGuardians = directories[victim] ??= await coGuardiansOf(victim);
        final sender = coGuardians.where((g) => g.nodeId == from).firstOrNull;
        if (env['toNodeId'] != me || sender == null) {
          throw UntrustedLedgerRecord('sender is not a current co-guardian');
        }
        final pieceHash = crypto.sha256.convert(base64Decode(sealed)).toString();
        if (pieceHash != env['pieceHash'] ||
            !await _verifyEd25519(sender.ed25519PublicKey, forwardPayload(hash, victim, from, me, pieceHash),
                env['signature'] as String) ||
            env['senderX25519'] != sender.x25519PublicKey) {
          throw UntrustedLedgerRecord("piece isn't signed by its sender");
        }
        final share = Map<String, dynamic>.from(env['share'] as Map? ?? const {});
        await Hive.box(MeshService.receivedSharesBoxName).put('$hash:fwd:$from', {
          ...share,
          'manifestHash': hash,
          'victimNodeId': victim,
          'senderNodeId': from,
          'senderX25519': sender.x25519PublicKey,
          'sealedShare': sealed,
          'forwardedBy': from,
          'viaMailbox': true,
          'receivedAt': DateTime.now().toIso8601String(),
        });
        stored++;
        done.add(id);
      } on UntrustedLedgerRecord catch (e) {
        developer.log('Dropped mailbox piece $id: $e', name: 'JusticeChain.CoGuardian');
        done.add(id);
      } catch (e) {
        // Offline or the gateway is down: what's left stays for next time.
        developer.log('Mailbox check stopped: $e', name: 'JusticeChain.CoGuardian');
        break;
      }
    }

    if (done.isNotEmpty) {
      final payload = 'justice-chain/ack-pieces/v1|$me|${([...done]..sort()).join(',')}';
      await ledger.ackPieces(me, {'ids': done, 'signature': await IdentityService.signBytes(utf8.encode(payload))});
    }
    return stored;
  }

  /// Stores a key piece sent by a victim's SOS device as this guardian's own
  /// piece of the clip (so it can be forwarded to co-guardians like any
  /// other). The device is trusted only through the victim's owner
  /// certificate, checked against her key saved at pairing. Returns null,
  /// leaving the piece in the mailbox, while this phone hasn't paired with her.
  static Future<int?> _storeDevicePiece(Map env, String me) async {
    final victim = env['victimNodeId'] as String;
    final contact = GuardianManager.getAllContacts()[victim];
    final victimKey = contact is Map ? contact['public_key'] as String? : null;
    if (victimKey == null) {
      developer.log('Keeping device piece from $victim until this phone pairs with them', name: 'JusticeChain.CoGuardian');
      return null;
    }
    if (!await DeviceLinkService.verifyDevicePiece(env, me: me, victimEd25519: victimKey)) {
      throw UntrustedLedgerRecord("device piece doesn't check out");
    }
    final hash = env['manifestHash'] as String;
    final from = env['fromNodeId'] as String;
    final cert = Map<String, dynamic>.from(env['certificate'] as Map);
    await Hive.box(MeshService.receivedSharesBoxName).put('$hash:dev:$from', {
      ...Map<String, dynamic>.from(env['share'] as Map? ?? const {}),
      'manifestHash': hash,
      'victimNodeId': victim,
      'senderNodeId': from,
      'senderX25519': env['senderX25519'],
      'sealedShare': env['sealedShare'],
      'deviceCertificate': cert,
      'viaMailbox': true,
      'receivedAt': DateTime.now().toIso8601String(),
    });
    return 1;
  }
}
