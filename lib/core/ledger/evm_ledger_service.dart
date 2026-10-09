import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';

import 'ledger_service.dart';

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
  },
  {
    "anonymous": false,
    "inputs": [
      {"indexed": true, "internalType": "bytes32", "name": "manifestHash", "type": "bytes32"},
      {"indexed": false, "internalType": "string", "name": "cid", "type": "string"},
      {"indexed": false, "internalType": "uint64", "name": "capturedAt", "type": "uint64"},
      {"indexed": true, "internalType": "bytes32", "name": "nodeId", "type": "bytes32"},
      {"indexed": true, "internalType": "address", "name": "signer", "type": "address"}
    ],
    "name": "EvidenceAnchored",
    "type": "event"
  }
]
''';

/// Anchors evidence manifests on an EVM chain running JusticeLedger.sol
/// (local Hardhat today, Polygon Amoy in Phase 7). The device's own
/// anchoring key only ever signs — a separate funded account pays gas and
/// submits, so anchoring never requires the victim to hold crypto.
class EvmLedgerService implements LedgerService {
  EvmLedgerService({
    required this.rpcUrl,
    required this.contractAddress,
    required this.submitterPrivateKey,
  });

  final String rpcUrl;
  final String contractAddress;
  final String submitterPrivateKey;

  Web3Client? _client;

  @override
  String get name => 'Hardhat (EVM)';

  Web3Client _getClient() => _client ??= Web3Client(rpcUrl, http.Client());

  DeployedContract _getContract() => DeployedContract(
        ContractAbi.fromJson(_justiceLedgerAbi, 'JusticeLedger'),
        EthereumAddress.fromHex(contractAddress),
      );

  /// Pads/truncates [hexId] (the app's 16-hex-char node ID) into a
  /// left-aligned bytes32, matching how the contract treats node IDs as
  /// opaque 32-byte values.
  static Uint8List _nodeIdToBytes32(String hexId) {
    final idBytes = hexToBytes(hexId);
    final padded = Uint8List(32);
    padded.setRange(0, idBytes.length, idBytes);
    return padded;
  }

  @override
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  }) {
    final contract = _getContract();
    return _getClient().sendTransaction(
      EthPrivateKey.fromHex(submitterPrivateKey),
      Transaction.callContract(
        contract: contract,
        function: contract.function('storeEvidence'),
        parameters: [
          Uint8List.fromList(hexToBytes(manifestHashHex)),
          cid,
          BigInt.from(capturedAt.millisecondsSinceEpoch ~/ 1000),
          _nodeIdToBytes32(nodeId),
          hexToBytes(signatureHex),
        ],
      ),
      // web3dart defaults to chainId 1 (mainnet) if unset, which Hardhat's
      // local chain (31337 by default) rejects as "signed for another
      // chain." Fetching it from the node avoids hardcoding a chain ID
      // that would also need updating for the later public-testnet step.
      chainId: null,
      fetchChainIdFromNetworkId: true,
    );
  }

  @override
  Future<AnchorBlock?> findAnchorBlock(String manifestHashHex) async {
    final client = _getClient();
    final contract = _getContract();
    final event = contract.event('EvidenceAnchored');

    final logs = await client.getLogs(
      FilterOptions(
        address: contract.address,
        fromBlock: const BlockNum.genesis(),
        toBlock: const BlockNum.current(),
        topics: [
          [bytesToHex(event.signature, padToEvenLength: true, include0x: true)],
          [bytesToHex(hexToBytes(manifestHashHex), padToEvenLength: true, include0x: true)],
        ],
      ),
    );
    final blockNumber = logs.isEmpty ? null : logs.first.blockNum;
    if (blockNumber == null) return null;

    final block = await client.getBlockInformation(
      blockNumber: BlockNum.exact(blockNumber).toBlockParam(),
    );
    return (blockNumber: blockNumber, blockTime: block.timestamp.toLocal());
  }

  @override
  Future<AnchorVerificationResult> verifyEvidence(String manifestHashHex) async {
    final contract = _getContract();
    final result = await _getClient().call(
      contract: contract,
      function: contract.function('verifyEvidence'),
      params: [Uint8List.fromList(hexToBytes(manifestHashHex))],
    );

    final capturedAtSeconds = (result[2] as BigInt).toInt();
    final anchoredAtSeconds = (result[3] as BigInt).toInt();
    return AnchorVerificationResult(
      found: result[0] as bool,
      cid: result[1] as String,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(capturedAtSeconds * 1000),
      anchoredAt: DateTime.fromMillisecondsSinceEpoch(anchoredAtSeconds * 1000),
      nodeId: bytesToHex(result[4] as Uint8List, include0x: false),
      signer: (result[5] as EthereumAddress).eip55With0x,
    );
  }

  @override
  Future<List<String>> getEvidenceHistory(String nodeId) async {
    final contract = _getContract();
    final result = await _getClient().call(
      contract: contract,
      function: contract.function('getEvidenceHistory'),
      params: [_nodeIdToBytes32(nodeId)],
    );
    return [
      for (final hash in result[0] as List) bytesToHex(hash as Uint8List, include0x: false),
    ];
  }
}
