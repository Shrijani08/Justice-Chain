import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../logic/guardian_manager.dart';
import 'anchoring_service.dart';
import 'evidence_encryptor.dart';
import 'evidence_vault_service.dart';
import 'identity_service.dart';
import 'ledger/fabric_ledger_service.dart';
import 'outbox_service.dart';

/// Demo builds only: `flutter run --dart-define=DEMO_AUTHORITY=true`. The
/// police authority on the Fabric network is SIMULATED; a normal build never
/// offers it, so no real user can believe they have reported to the police.
const bool kDemoAuthorityBuild = bool.fromEnvironment('DEMO_AUTHORITY');

/// This phone's presence on the Fabric ledger, and sharing key pieces with
/// a registered authority (design doc Step 8, app part).
///
/// Everything here runs from the outbox, so it retries offline. The ledger
/// checks every signature itself: the phone registers its ID with both of its
/// keys, signs its guardian list, and signs a consent for each piece it gives
/// an authority, so the gateway can't act on the phone's behalf.
class AuthorityService {
  AuthorityService._();

  static const String simPoliceMsp = 'SimPoliceMSP';
  static const int maxLedgerGuardians = 10; // the chaincode's limit

  static const String _optInKey = 'authority_guardian_msp';
  static const String _registeredKey = 'ledger_node_registered';

  static Box get _box => Hive.box('vault_box');

  @visibleForTesting
  static FabricLedgerService? gatewayForTest;
  @visibleForTesting
  static bool? demoBuildForTest;

  static FabricLedgerService? _gateway;

  /// The Fabric gateway when LEDGER=fabric, else null (EVM has no registry).
  static FabricLedgerService? get _ledger {
    if (gatewayForTest != null) return gatewayForTest;
    try {
      if ((dotenv.env['LEDGER'] ?? '').trim().toLowerCase() != 'fabric') return null;
      final url = dotenv.env['GATEWAY_URL']?.trim() ?? '';
      if (url.isEmpty) return null;
      return _gateway ??= FabricLedgerService(gatewayUrl: url);
    } catch (_) {
      return null; // .env not loaded (tests, early start-up)
    }
  }

  static FabricLedgerService _requireLedger() =>
      _ledger ?? (throw StateError('Phone registry needs LEDGER=fabric and GATEWAY_URL in .env'));

  /// True when the app talks to the Fabric gateway.
  static bool get ledgerFeaturesEnabled => _ledger != null;

  static bool get demoBuild => demoBuildForTest ?? kDemoAuthorityBuild;

  /// Whether the user has opted in to giving the simulated authority one
  /// key piece of each new recording.
  static bool get sharesWithAuthority => _box.get(_optInKey) != null;

  static Future<void> setShareWithAuthority(bool on) async {
    if (on && !demoBuild) throw StateError('The authority guardian exists only in demo builds');
    if (on) {
      await _box.put(_optInKey, simPoliceMsp);
    } else {
      await _box.delete(_optInKey);
    }
  }

  /// The authority a recording made now should be shared with, or null.
  /// Decided at recording time, like the threshold: opting in never shares
  /// recordings made before it.
  static String? authorityForNewRecordings() =>
      demoBuild && ledgerFeaturesEnabled ? _box.get(_optInKey) as String? : null;

  static String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

  /// The ledger's action signatures: EIP-191 by the anchoring key over the
  /// SHA-256 of the action text (as the chaincode's recoverActionSigner).
  static Future<String> _signAction(String payload) =>
      AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload)));

  // Outbox entry points

  static Future<void> requestRegistration() async {
    if (!ledgerFeaturesEnabled) return;
    await OutboxService.enqueue(OutboxService.jobRegisterNode, OutboxService.jobRegisterNode, const {});
  }

  /// Queues a fresh guardian-list sync, replacing any queued one so a change
  /// isn't held back by an earlier attempt's backoff.
  static Future<void> requestGuardianSync() async {
    if (!ledgerFeaturesEnabled) return;
    await OutboxService.enqueueNow(OutboxService.jobGuardianSync, OutboxService.jobGuardianSync, const {});
  }

  // The work

  /// Registers this phone's ID and keys on the ledger, once. The payload is
  /// signed by both keys, so no one can claim this phone's ID; repeating it
  /// with the same keys is accepted by the ledger.
  static Future<void> registerThisPhone() async {
    final ledger = _requireLedger();
    final nodeId = await IdentityService.getMyNodeId();
    if (_box.get(_registeredKey) == nodeId) return;

    final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
    final edKey = qr['public_key'] as String;
    final xKey = qr['x25519_public_key'] as String;
    final address = (qr['anchoring_address'] as String).toLowerCase();
    final payload = 'justice-chain/register-node/v1|$nodeId|$edKey|$xKey|$address';

    await ledger.registerNode({
      'nodeId': nodeId,
      'ed25519PublicKey': edKey,
      'x25519PublicKey': xKey,
      'anchoringAddress': address,
      'ed25519Signature': await IdentityService.signBytes(utf8.encode(payload)),
      'anchoringSignature': await _signAction(payload),
    });
    await _box.put(_registeredKey, nodeId);
    developer.log('Phone $nodeId registered on the ledger.', name: 'JusticeChain.Authority');
  }

  /// Makes the ledger's guardian list match this phone's trusted guardians.
  /// The ledger only accepts registered phones, so a guardian who hasn't
  /// opened Sakshya yet is left out and the sync throws, which makes the
  /// outbox try again later; once they register, they are added.
  static Future<void> syncGuardians() async {
    final ledger = _requireLedger();
    await registerThisPhone();
    final me = await IdentityService.getMyNodeId();

    final wanted = GuardianManager.getTrustedGuardians().keys.cast<String>().toList()..sort();
    final registered = <String>[];
    final waiting = <String>[];
    for (final id in wanted) {
      ((await ledger.getNode(id))['found'] == true ? registered : waiting).add(id);
    }
    final ids = registered.take(maxLedgerGuardians).toList();

    final current = await ledger.getGuardians(me);
    final onLedger = current['found'] == true;
    final currentIds = onLedger ? List<String>.from(current['guardians'] as List) : const <String>[];
    // Nothing to write when the list already matches, or when it was never
    // set and there is no one to name yet.
    if (!listEquals(currentIds, ids) && (onLedger || ids.isNotEmpty)) {
      // The ledger refuses a sequence that doesn't grow; reading it back
      // first keeps a reinstalled phone from getting stuck behind its old one.
      final sequence = (onLedger ? current['sequence'] as int : 0) + 1;
      await ledger.setGuardians({
        'victimNodeId': me,
        'guardianNodeIds': ids,
        'sequence': sequence,
        'signature': await _signAction('justice-chain/set-guardians/v1|$me|$sequence|${ids.join(',')}'),
      });
      developer.log('Guardian list on the ledger set to ${ids.length} (sequence $sequence).',
          name: 'JusticeChain.Authority');
    }
    if (waiting.isNotEmpty) {
      throw StateError('Waiting for ${waiting.length} guardian(s) to register on the ledger');
    }
  }

  /// Gives the record's authority one sealed key piece, with the victim's
  /// signed consent for exactly that piece. Runs after the record is
  /// anchored, because the ledger checks the anchor's signer.
  static Future<void> shareRecordWithAuthority(String recordKey) async {
    final raw = _box.get(recordKey);
    if (raw is! Map) return;
    var record = Map<String, dynamic>.from(raw);
    final msp = record['authorityMsp'] as String?;
    if (msp == null || record['authorityShare'] != null) return;

    // With a threshold of one, a single piece is the whole key: the authority
    // could open the clip alone. Such recordings are never shared.
    final threshold = EvidenceVaultService.recordThreshold(record);
    if (threshold < EvidenceEncryptor.guardianQuorum) {
      record['authorityShare'] = {'msp': msp, 'skipped': 'single-guardian recording'};
      await _box.put(recordKey, record);
      developer.log('Not sharing $recordKey with $msp: single-guardian recording.',
          name: 'JusticeChain.Authority');
      return;
    }
    if (record['status'] != 'anchored') throw const JobNotReady();

    final ledger = _requireLedger();
    await registerThisPhone();
    final authority = await ledger.getAuthority(msp);
    if (authority['found'] != true || authority['revoked'] == true) {
      throw StateError('$msp is not an active registered authority');
    }

    // The piece's index comes from the same counter as guardians' pieces, and
    // is kept so a retry seals the same piece.
    record = Map<String, dynamic>.from(_box.get(recordKey) as Map);
    var x = record['authorityShareX'] as int?;
    if (x == null) {
      x = (record['nextShareX'] as int?) ??
          ((record['guardianShares'] as Map?)?.length ?? 0) + 1;
      record['authorityShareX'] = x;
      record['nextShareX'] = x + 1;
      await _box.put(recordKey, record);
    }

    final sealed = await EvidenceEncryptor.issueGuardianShare(
      wrappedKeyB64: record['wrappedKey'] as String,
      x: x,
      guardianX25519PublicKeyB64: authority['publicKey'] as String,
      threshold: threshold,
    );
    final consent = 'justice-chain/share-with-authority/v1|$recordKey|$msp|$x|$threshold|'
        '${_sha256Hex(base64Decode(sealed))}';

    Map<String, dynamic>? result;
    try {
      result = await ledger.shareWithAuthority({
        'manifestHash': recordKey,
        'authorityMsp': msp,
        'shareX': x,
        'threshold': threshold,
        'sealedShare': sealed,
        'signature': await _signAction(consent),
      });
    } on LedgerRefusedException catch (e) {
      // A retry after a commit whose reply was lost.
      if (!e.message.contains('already shared')) rethrow;
    }

    record = Map<String, dynamic>.from(_box.get(recordKey) as Map)
      ..['authorityShare'] = {
        'msp': msp,
        'x': x,
        'sharedAt': DateTime.now().toIso8601String(),
        if (result?['blockNumber'] != null) 'blockNumber': result!['blockNumber'],
      };
    await _box.put(recordKey, record);
    developer.log('Shared key piece $x of $recordKey with $msp.', name: 'JusticeChain.Authority');
  }
}
