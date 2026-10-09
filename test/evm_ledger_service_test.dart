import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/ledger/evm_ledger_service.dart';
import 'package:web3dart/web3dart.dart';

// Live check of EvmLedgerService against a local Hardhat node running
// JusticeLedger.sol. Run with:
//   npx hardhat node                       (in another terminal)
//   npx hardhat run scripts/deploy.js --network localhost
//   HARDHAT_RPC_URL=http://127.0.0.1:8545 HARDHAT_CONTRACT_ADDRESS=<address> \
//     flutter test test/evm_ledger_service_test.dart
void main() {
  final rpcUrl = Platform.environment['HARDHAT_RPC_URL'];
  final contractAddress = Platform.environment['HARDHAT_CONTRACT_ADDRESS'];

  test(
    'live: a Dart-signed anchor round-trips through JusticeLedger.sol',
    () async {
      // Hardhat's public test account #0 both signs and pays gas here.
      const testKey = 'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
      const node = '0123456789abcdef';
      final key = EthPrivateKey.fromHex(testKey);
      final ledger = EvmLedgerService(
        rpcUrl: rpcUrl!,
        contractAddress: contractAddress!,
        submitterPrivateKey: testKey,
      );
      final hash = crypto.sha256
          .convert(utf8.encode('justice-chain evm live test ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}'))
          .toString();
      final signature = bytesToHex(key.signPersonalMessageToUint8List(hexToBytes(hash)));

      expect((await ledger.verifyEvidence(hash)).found, isFalse);

      final txHash = await ledger.recordAnchor(
        manifestHashHex: hash,
        cid: 'bafyevmlivetest',
        capturedAt: DateTime.now(),
        nodeId: node,
        signatureHex: signature,
      );
      expect(txHash, startsWith('0x'));

      final record = await ledger.verifyEvidence(hash);
      expect(record.found, isTrue);
      expect(record.cid, 'bafyevmlivetest');
      expect(record.signer.toLowerCase(), '0x${key.address.toString().toLowerCase()}');
      expect(record.anchoredAtIsLedgerTime, isTrue);
      expect(record.nodeId, startsWith(node));

      final block = await ledger.findAnchorBlock(hash);
      expect(block?.blockNumber, greaterThan(0));
      expect(block?.blockTime, isNotNull);

      expect(await ledger.getEvidenceHistory(node), contains(hash));
    },
    skip: rpcUrl == null || contractAddress == null
        ? 'Set HARDHAT_RPC_URL and HARDHAT_CONTRACT_ADDRESS to run against a Hardhat node'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
