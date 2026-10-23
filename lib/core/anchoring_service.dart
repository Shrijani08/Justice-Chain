import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:web3dart/web3dart.dart';

import 'identity_service.dart';
import 'ledger/evm_ledger_service.dart';
import 'ledger/fabric_ledger_service.dart';
import 'ledger/ledger_service.dart';

export 'ledger/ledger_service.dart' show AnchorBlock, AnchorVerificationResult;

/// The app's one entry point for anchoring evidence. Which ledger it uses
/// comes from LEDGER in .env:
///   evm    (default) JusticeLedger.sol via RPC_URL, CONTRACT_ADDRESS and
///          HARDHAT_SUBMITTER_PRIVATE_KEY
///   fabric the Hyperledger Fabric gateway at GATEWAY_URL
/// Every method logs and returns null on failure instead of throwing:
/// anchoring is additive proof, and must never undo or block an IPFS
/// upload that already succeeded.
class AnchoringService {
  AnchoringService._();

  static LedgerService? _ledger;

  /// Replaces the ledger chosen from .env, for tests.
  @visibleForTesting
  static set ledgerForTest(LedgerService? ledger) => _ledger = ledger;

  static LedgerService _selectedLedger() => _ledger ??= ledgerFromEnv(dotenv.env);

  /// The ledger [env] (the loaded .env) selects; throws if misconfigured.
  @visibleForTesting
  static LedgerService ledgerFromEnv(Map<String, String> env) {
    String required(String key) {
      final value = env[key]?.trim();
      if (value == null || value.isEmpty) {
        throw StateError('$key not configured in .env');
      }
      return value;
    }

    final ledger = (env['LEDGER'] ?? 'evm').trim().toLowerCase();
    return switch (ledger) {
      'evm' => EvmLedgerService(
          rpcUrl: required('RPC_URL'),
          contractAddress: required('CONTRACT_ADDRESS'),
          submitterPrivateKey: required('HARDHAT_SUBMITTER_PRIVATE_KEY'),
        ),
      'fabric' => FabricLedgerService(gatewayUrl: required('GATEWAY_URL'), apiKey: env['GATEWAY_API_KEY']),
      _ => throw StateError('LEDGER in .env must be "evm" or "fabric", not "$ledger"'),
    };
  }

  static Future<T?> _attempt<T>(String what, Future<T> Function(LedgerService) action) async {
    try {
      return await action(_selectedLedger());
    } catch (e, stackTrace) {
      developer.log(
        '$what failed on ${_ledger?.name ?? 'the configured ledger'}',
        error: e,
        stackTrace: stackTrace,
        name: 'JusticeChain.Anchor',
      );
      return null;
    }
  }

  /// This device's anchoring signature over [manifestHashHex], hex-encoded.
  /// Carried in relay manifests so a guardian can anchor on the victim's
  /// behalf — the ledger recovers the victim as signer whoever submits.
  static Future<String> signAnchor(String manifestHashHex) async {
    final anchoringKey = await IdentityService.getAnchoringCredentials();
    return bytesToHex(
      anchoringKey.signPersonalMessageToUint8List(hexToBytes(manifestHashHex)),
    );
  }

  /// Anchors one evidence manifest. Returns the transaction ID, or null on
  /// any failure, including the ledger refusing a duplicate (callers check
  /// verifyEvidence first and retry, so a duplicate resolves next attempt).
  static Future<String?> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    String? signatureHex,
  }) async {
    final txId = await _attempt('Anchoring (evidence remains safely uploaded regardless)', (ledger) async {
      return ledger.recordAnchor(
        manifestHashHex: manifestHashHex,
        cid: cid,
        capturedAt: capturedAt,
        nodeId: nodeId,
        signatureHex: signatureHex ?? await signAnchor(manifestHashHex),
      );
    });
    if (txId != null) {
      developer.log('Evidence anchored on ${_ledger?.name}. Tx: $txId', name: 'JusticeChain.Anchor');
    }
    return txId;
  }

  /// Finds the block that recorded [manifestHashHex]'s anchor. Null if not
  /// found or the ledger is unreachable. blockTime is null on Fabric.
  static Future<AnchorBlock?> findAnchorBlock(String manifestHashHex) =>
      _attempt<AnchorBlock?>('Anchor block lookup', (ledger) => ledger.findAnchorBlock(manifestHashHex));

  /// Looks up an anchor by manifest hash, for a guardian/court verification
  /// screen. Returns null if the ledger is unreachable or misconfigured.
  static Future<AnchorVerificationResult?> verifyEvidence(String manifestHashHex) =>
      _attempt('Anchor verification', (ledger) => ledger.verifyEvidence(manifestHashHex));

  /// Every manifest hash anchored under [nodeId], in anchoring order; null
  /// if the ledger is unreachable. For restoring a victim's evidence list.
  static Future<List<String>?> getEvidenceHistory(String nodeId) =>
      _attempt('Evidence history lookup', (ledger) => ledger.getEvidenceHistory(nodeId));
}
