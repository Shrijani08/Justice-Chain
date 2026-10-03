import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';
import 'dart:developer' as developer;

import 'identity_service.dart';

/// The minimal ABI for the three JusticeLedger v2 functions this client
/// calls — not the full Hardhat build artifact, so the app doesn't depend
/// on build output paths.
const String _justiceLedgerAbi = '''
[
  {
    "inputs": [
      {"internalType": "bytes32", "name": "manifestHash", "type": "bytes32"},
      {"internalType": "string", "name": "cid", "type": "string"},
      {"internalType": "uint64", "name": "capturedAt", "type": "uint64"},
      {"internalType": "bytes32", "name": "nodeId", "type": "bytes32"},
      {"internalType": "bytes", "name": "sig", "type": "bytes"}
    ],
    "name": "storeEvidence",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {"internalType": "bytes32", "name": "manifestHash", "type": "bytes32"}
    ],
    "name": "verifyEvidence",
    "outputs": [
      {"internalType": "bool", "name": "found", "type": "bool"},
      {"internalType": "string", "name": "cid", "type": "string"},
      {"internalType": "uint64", "name": "capturedAt", "type": "uint64"},
      {"internalType": "uint64", "name": "anchoredAt", "type": "uint64"},
      {"internalType": "bytes32", "name": "nodeId", "type": "bytes32"},
      {"internalType": "address", "name": "signer", "type": "address"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"internalType": "bytes32", "name": "nodeId", "type": "bytes32"}
    ],
    "name": "getEvidenceHistory",
    "outputs": [
      {"internalType": "bytes32[]", "name": "", "type": "bytes32[]"}
    ],
    "stateMutability": "view",
    "type": "function"
  }
]
''';

class AnchorVerificationResult {
  const AnchorVerificationResult({
    required this.found,
    required this.cid,
    required this.capturedAt,
    required this.anchoredAt,
    required this.nodeId,
    required this.signer,
  });

  final bool found;
  final String cid;
  final DateTime capturedAt;
  final DateTime anchoredAt;
  final String nodeId;
  final String signer;
}

/// Anchors evidence manifests on a local Hardhat chain (blueprint Phase 3,
/// "Local Hardhat" step). The device's own anchoring key only ever signs —
/// a separate funded account (configured via .env, local-chain only) pays
/// gas and submits, so anchoring never requires the victim to hold crypto.
class AnchoringService {
  AnchoringService._();

  static Web3Client? _client;

  static Web3Client _getClient() {
    final rpcUrl = dotenv.env['RPC_URL'];
    if (rpcUrl == null || rpcUrl.isEmpty) {
      throw StateError('RPC_URL not configured in .env');
    }
    return _client ??= Web3Client(rpcUrl, http.Client());
  }

  static DeployedContract _getContract() {
    final address = dotenv.env['CONTRACT_ADDRESS'];
    if (address == null || address.isEmpty) {
      throw StateError('CONTRACT_ADDRESS not configured in .env');
    }
    return DeployedContract(
      ContractAbi.fromJson(_justiceLedgerAbi, 'JusticeLedger'),
      EthereumAddress.fromHex(address),
    );
  }

  static EthPrivateKey _getSubmitterCredentials() {
    final key = dotenv.env['HARDHAT_SUBMITTER_PRIVATE_KEY'];
    if (key == null || key.isEmpty) {
      throw StateError('HARDHAT_SUBMITTER_PRIVATE_KEY not configured in .env');
    }
    return EthPrivateKey.fromHex(key);
  }

  /// Pads/truncates [hexId] (the app's 16-hex-char node ID) into a
  /// left-aligned bytes32, matching how the contract treats node IDs as
  /// opaque 32-byte values.
  static Uint8List _nodeIdToBytes32(String hexId) {
    final idBytes = hexToBytes(hexId);
    final padded = Uint8List(32);
    padded.setRange(0, idBytes.length, idBytes);
    return padded;
  }

  /// Anchors one evidence manifest on-chain. Never throws into the caller
  /// on failure (unreachable chain, bad config, etc.) — anchoring is
  /// additive proof, not a condition for evidence being safely uploaded,
  /// so a failure here must never undo or block the IPFS upload that
  /// already succeeded.
  static Future<String?> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
  }) async {
    try {
      final client = _getClient();
      final contract = _getContract();
      final submitter = _getSubmitterCredentials();
      final anchoringKey = await IdentityService.getAnchoringCredentials();

      final manifestHashBytes = hexToBytes(manifestHashHex);
      final signature = anchoringKey.signPersonalMessageToUint8List(
        manifestHashBytes,
      );

      final function = contract.function('storeEvidence');
      final txHash = await client.sendTransaction(
        submitter,
        Transaction.callContract(
          contract: contract,
          function: function,
          parameters: [
            Uint8List.fromList(manifestHashBytes),
            cid,
            BigInt.from(capturedAt.millisecondsSinceEpoch ~/ 1000),
            _nodeIdToBytes32(nodeId),
            signature,
          ],
        ),
        // web3dart defaults to chainId 1 (mainnet) if unset, which Hardhat's
        // local chain (31337 by default) rejects as "signed for another
        // chain." Fetching it from the node avoids hardcoding a chain ID
        // that would also need updating for the later public-testnet step.
        chainId: null,
        fetchChainIdFromNetworkId: true,
      );

      developer.log(
        'Evidence anchored on-chain. Tx: $txHash',
        name: 'JusticeChain.Anchor',
      );
      return txHash;
    } catch (e, stackTrace) {
      developer.log(
        'Anchoring failed (evidence remains safely uploaded regardless)',
        error: e,
        stackTrace: stackTrace,
        name: 'JusticeChain.Anchor',
      );
      return null;
    }
  }

  /// Looks up an anchor by manifest hash, for a guardian/court verification
  /// screen. Returns null if the chain is unreachable or misconfigured.
  static Future<AnchorVerificationResult?> verifyEvidence(
    String manifestHashHex,
  ) async {
    try {
      final client = _getClient();
      final contract = _getContract();
      final function = contract.function('verifyEvidence');

      final result = await client.call(
        contract: contract,
        function: function,
        params: [Uint8List.fromList(hexToBytes(manifestHashHex))],
      );

      final found = result[0] as bool;
      final cid = result[1] as String;
      final capturedAtSeconds = (result[2] as BigInt).toInt();
      final anchoredAtSeconds = (result[3] as BigInt).toInt();
      final nodeIdBytes = result[4] as Uint8List;
      final signer = result[5] as EthereumAddress;

      return AnchorVerificationResult(
        found: found,
        cid: cid,
        capturedAt: DateTime.fromMillisecondsSinceEpoch(
          capturedAtSeconds * 1000,
        ),
        anchoredAt: DateTime.fromMillisecondsSinceEpoch(
          anchoredAtSeconds * 1000,
        ),
        nodeId: bytesToHex(nodeIdBytes, include0x: false),
        signer: signer.eip55With0x,
      );
    } catch (e, stackTrace) {
      developer.log(
        'Anchor verification failed',
        error: e,
        stackTrace: stackTrace,
        name: 'JusticeChain.Anchor',
      );
      return null;
    }
  }
}
