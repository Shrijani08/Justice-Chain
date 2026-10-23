import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/guardian_evidence_service.dart';
import 'package:justice_chain/core/ledger/evm_ledger_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/ledger/ledger_service.dart';
import 'package:web3dart/web3dart.dart';

const _hash = '53f7a63576d0deb96daa84ac541364d061f43190d2a7a4204eeef6ffa49d290e';
const _node = '0123456789abcdef';
const _signer = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';

Map<String, dynamic> _record({int blockNumber = 8}) => {
      'found': true,
      'manifestHash': _hash,
      'cid': 'bafytest',
      'capturedAt': 1791399990,
      'anchoredAt': 1791400000,
      'nodeId': _node,
      'signer': _signer,
      'txId': 'tx123',
      'blockNumber': blockNumber,
    };

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A ledger that records calls and can be told to fail.
class _FakeLedger implements LedgerService {
  Object? failWith;
  String? lastSignature;

  @override
  String get name => 'fake';

  Future<T> _maybeFail<T>(T value) async {
    if (failWith != null) throw failWith!;
    return value;
  }

  @override
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  }) {
    lastSignature = signatureHex;
    return _maybeFail('tx-fake');
  }

  @override
  Future<AnchorVerificationResult> verifyEvidence(String manifestHashHex) => _maybeFail(
        AnchorVerificationResult(
          found: true,
          cid: 'c',
          capturedAt: DateTime(2026),
          anchoredAt: DateTime(2026),
          nodeId: _node,
          signer: _signer,
        ),
      );

  @override
  Future<AnchorBlock?> findAnchorBlock(String manifestHashHex) => _maybeFail((blockNumber: 1, blockTime: null));

  @override
  Future<List<String>> getEvidenceHistory(String nodeId) => _maybeFail([_hash]);
}

void main() {
  group('FabricLedgerService', () {
    test('recordAnchor posts the anchor as JSON and returns the transaction ID', () async {
      late http.Request sent;
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800/',
        client: MockClient((request) async {
          sent = request;
          return _json(_record());
        }),
      );

      final txId = await ledger.recordAnchor(
        manifestHashHex: _hash,
        cid: 'bafytest',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(1791399990 * 1000 + 999),
        nodeId: _node,
        signatureHex: 'ab' * 65,
      );

      expect(txId, 'tx123');
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://gw:8800/anchor');
      expect(sent.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), {
        'manifestHash': _hash,
        'cid': 'bafytest',
        'capturedAt': 1791399990,
        'nodeId': _node,
        'signature': 'ab' * 65,
      });
    });

    test('every request carries the API key; none is sent when there is no key', () async {
      final sent = <http.BaseRequest>[];
      MockClient client() => MockClient((request) async {
            sent.add(request);
            return request.method == 'POST' ? _json(_record()) : _json({'found': false, 'manifestHash': _hash});
          });
      final withKey = FabricLedgerService(gatewayUrl: 'http://gw:8800', apiKey: ' k3y ', client: client());
      await withKey.verifyEvidence(_hash);
      await withKey.recordAnchor(
        manifestHashHex: _hash,
        cid: 'bafytest',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(0),
        nodeId: _node,
        signatureHex: 'ab' * 65,
      );
      expect(sent.map((r) => r.headers['X-Api-Key']), ['k3y', 'k3y']);
      expect(sent.every((r) => r.headers['ngrok-skip-browser-warning'] == '1'), isTrue);

      sent.clear();
      await FabricLedgerService(gatewayUrl: 'http://gw:8800', client: client()).verifyEvidence(_hash);
      expect(sent.single.headers.containsKey('X-Api-Key'), isFalse);
    });

    test('a chaincode refusal (HTTP 400) throws LedgerRefusedException with its message', () async {
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((_) async => _json({'error': 'Evidence already stored'}, 400)),
      );
      await expectLater(
        ledger.recordAnchor(
          manifestHashHex: _hash,
          cid: 'c',
          capturedAt: DateTime(2026),
          nodeId: _node,
          signatureHex: 'ab' * 65,
        ),
        throwsA(isA<LedgerRefusedException>().having((e) => e.message, 'message', 'Evidence already stored')),
      );
    });

    test('a gateway or network failure throws StateError', () async {
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((_) async => _json({'error': 'Fabric network unavailable'}, 503)),
      );
      await expectLater(ledger.verifyEvidence(_hash), throwsStateError);
    });

    test('verifyEvidence parses a found record and marks its time as gateway time', () async {
      late Uri requested;
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((request) async {
          requested = request.url;
          return _json(_record());
        }),
      );

      final result = await ledger.verifyEvidence(_hash);

      expect(requested.path, '/verify/$_hash');
      expect(result.found, isTrue);
      expect(result.cid, 'bafytest');
      expect(result.signer, _signer);
      expect(result.nodeId, _node);
      expect(result.capturedAt.millisecondsSinceEpoch, 1791399990 * 1000);
      expect(result.anchoredAt.millisecondsSinceEpoch, 1791400000 * 1000);
      expect(result.anchoredAtIsLedgerTime, isFalse);
    });

    test('verifyEvidence reports found: false for an unknown hash', () async {
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((_) async => _json({'found': false, 'manifestHash': _hash})),
      );
      expect((await ledger.verifyEvidence(_hash)).found, isFalse);
    });

    test('findAnchorBlock returns the block number with no block time', () async {
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((_) async => _json(_record(blockNumber: 12))),
      );
      final block = await ledger.findAnchorBlock(_hash);
      expect(block?.blockNumber, 12);
      expect(block?.blockTime, isNull);
    });

    test('findAnchorBlock returns null for an unknown hash', () async {
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((_) async => _json({'found': false, 'manifestHash': _hash})),
      );
      expect(await ledger.findAnchorBlock(_hash), isNull);
    });

    test('getEvidenceHistory returns the hashes in order', () async {
      late Uri requested;
      final ledger = FabricLedgerService(
        gatewayUrl: 'http://gw:8800',
        client: MockClient((request) async {
          requested = request.url;
          return _json([_hash, 'aa' * 32]);
        }),
      );
      expect(await ledger.getEvidenceHistory(_node), [_hash, 'aa' * 32]);
      expect(requested.path, '/history/$_node');
    });
  });

  group('AnchoringService', () {
    late _FakeLedger fake;
    setUp(() => AnchoringService.ledgerForTest = fake = _FakeLedger());
    tearDown(() => AnchoringService.ledgerForTest = null);

    test('passes a relayed signature through unchanged and returns the transaction ID', () async {
      final txId = await AnchoringService.recordAnchor(
        manifestHashHex: _hash,
        cid: 'c',
        capturedAt: DateTime(2026),
        nodeId: _node,
        signatureHex: 'cd' * 65,
      );
      expect(txId, 'tx-fake');
      expect(fake.lastSignature, 'cd' * 65);
    });

    test('turns every ledger failure into null instead of throwing', () async {
      fake.failWith = LedgerRefusedException('Evidence already stored');
      expect(
        await AnchoringService.recordAnchor(
          manifestHashHex: _hash,
          cid: 'c',
          capturedAt: DateTime(2026),
          nodeId: _node,
          signatureHex: 'cd' * 65,
        ),
        isNull,
      );
      fake.failWith = StateError('unreachable');
      expect(await AnchoringService.verifyEvidence(_hash), isNull);
      expect(await AnchoringService.findAnchorBlock(_hash), isNull);
      expect(await AnchoringService.getEvidenceHistory(_node), isNull);
    });
  });

  group('AnchoringService.ledgerFromEnv', () {
    test('defaults to the EVM ledger', () {
      expect(
        AnchoringService.ledgerFromEnv({
          'RPC_URL': 'http://x:8545',
          'CONTRACT_ADDRESS': '0x5FbDB2315678afecb367f032d93F642f64180aa3',
          'HARDHAT_SUBMITTER_PRIVATE_KEY': 'ab' * 32,
        }),
        isA<EvmLedgerService>(),
      );
    });

    test('LEDGER=fabric (any case, spaces trimmed) selects the Fabric gateway', () {
      expect(
        AnchoringService.ledgerFromEnv({'LEDGER': ' Fabric ', 'GATEWAY_URL': 'http://x:8800'}),
        isA<FabricLedgerService>(),
      );
    });

    test('a missing setting or unknown LEDGER is a clear error', () {
      expect(
        () => AnchoringService.ledgerFromEnv({'LEDGER': 'fabric'}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('GATEWAY_URL'))),
      );
      expect(
        () => AnchoringService.ledgerFromEnv({'RPC_URL': 'http://x:8545'}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('CONTRACT_ADDRESS'))),
      );
      expect(
        () => AnchoringService.ledgerFromEnv({'LEDGER': 'polygon'}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('"evm" or "fabric"'))),
      );
    });
  });

  group('GuardianEvidenceService.describeAnchor', () {
    AnchorVerificationResult anchor({required bool ledgerTime}) => AnchorVerificationResult(
          found: true,
          cid: 'c',
          capturedAt: DateTime(2026, 10, 9, 10),
          anchoredAt: DateTime(2026, 10, 9, 11, 5),
          nodeId: _node,
          signer: _signer,
          anchoredAtIsLedgerTime: ledgerTime,
        );

    test('EVM: block number and block time', () {
      expect(
        GuardianEvidenceService.describeAnchor(
          (blockNumber: 7, blockTime: DateTime(2026, 10, 9, 11, 6)),
          anchor(ledgerTime: true),
        ),
        'anchored in block 7 at 2026-10-09 11:06',
      );
    });

    test('Fabric: block number, and the time is labelled as the gateway\'s', () {
      expect(
        GuardianEvidenceService.describeAnchor((blockNumber: 8, blockTime: null), anchor(ledgerTime: false)),
        'anchored in block 8 · gateway time 2026-10-09 11:05',
      );
    });

    test('Fabric without a block number still labels gateway time', () {
      expect(
        GuardianEvidenceService.describeAnchor(null, anchor(ledgerTime: false)),
        'anchored · gateway time 2026-10-09 11:05',
      );
    });
  });

  // Live end-to-end check against the running gateway and chaincode. Run with:
  //   FABRIC_GATEWAY_URL=http://localhost:8800 flutter test test/fabric_ledger_service_test.dart
  // Each run anchors one new test record (permanent) under the test node ID.
  final gatewayUrl = Platform.environment['FABRIC_GATEWAY_URL'];
  test(
    'live: a Dart-signed anchor round-trips through the gateway and chaincode',
    () async {
      // Hardhat's public test account #0, never used for real funds.
      final key = EthPrivateKey.fromHex('ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
      final hash = crypto.sha256
          .convert(utf8.encode('justice-chain dart live test ${DateTime.now().microsecondsSinceEpoch} ${Random().nextInt(1 << 32)}'))
          .toString();
      final signature = bytesToHex(key.signPersonalMessageToUint8List(hexToBytes(hash)));
      final ledger = FabricLedgerService(gatewayUrl: gatewayUrl!, apiKey: Platform.environment['FABRIC_GATEWAY_API_KEY']);

      expect((await ledger.verifyEvidence(hash)).found, isFalse);

      final txId = await ledger.recordAnchor(
        manifestHashHex: hash,
        cid: 'bafydartlivetest',
        capturedAt: DateTime.now(),
        nodeId: _node,
        signatureHex: signature,
      );
      expect(txId, isNotEmpty);

      final record = await ledger.verifyEvidence(hash);
      expect(record.found, isTrue);
      expect(record.signer, _signer);
      expect(record.cid, 'bafydartlivetest');

      final block = await ledger.findAnchorBlock(hash);
      expect(block?.blockNumber, greaterThan(0));
      expect(block?.blockTime, isNull);

      expect(await ledger.getEvidenceHistory(_node), contains(hash));

      await expectLater(
        ledger.recordAnchor(
          manifestHashHex: hash,
          cid: 'bafydartlivetest',
          capturedAt: DateTime.now(),
          nodeId: _node,
          signatureHex: signature,
        ),
        throwsA(isA<LedgerRefusedException>().having((e) => e.message, 'message', 'Evidence already stored')),
      );
    },
    skip: gatewayUrl == null ? 'Set FABRIC_GATEWAY_URL to run against the live gateway' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
