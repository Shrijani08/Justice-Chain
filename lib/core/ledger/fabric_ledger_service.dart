import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ledger_service.dart';

/// The gateway rejected a request with the chaincode's own reason, e.g.
/// "Evidence already stored" or a malformed signature.
class LedgerRefusedException implements Exception {
  LedgerRefusedException(this.message);
  final String message;

  @override
  String toString() => 'Ledger refused: $message';
}

/// Anchors evidence on the Hyperledger Fabric network through the
/// Justice-Chain gateway (fabric/gateway/server.js). Phones have no Fabric
/// SDK, so the gateway submits for them; the device signature inside each
/// anchor is checked by the chaincode, so the gateway can't forge one.
class FabricLedgerService implements LedgerService {
  FabricLedgerService({required String gatewayUrl, http.Client? client})
      : _base = gatewayUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  final String _base;
  final http.Client _client;

  // Anchoring waits for the commit on both organisations' peers.
  static const _submitTimeout = Duration(seconds: 90);
  static const _queryTimeout = Duration(seconds: 15);

  @override
  String get name => 'Hyperledger Fabric';

  Future<dynamic> _decode(http.Response response) async {
    final body = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode == 200) return body;
    final message = body is Map ? body['error'] as String? : null;
    if (response.statusCode == 400) {
      throw LedgerRefusedException(message ?? 'bad request');
    }
    throw StateError('Fabric gateway HTTP ${response.statusCode}: ${message ?? response.body}');
  }

  Future<dynamic> _get(String path) async =>
      _decode(await _client.get(Uri.parse('$_base$path')).timeout(_queryTimeout));

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final response = await _client
        .post(
          Uri.parse('$_base$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_submitTimeout);
    return await _decode(response) as Map<String, dynamic>;
  }

  @override
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  }) async {
    final record = await _post('/anchor', {
      'manifestHash': manifestHashHex,
      'cid': cid,
      'capturedAt': capturedAt.millisecondsSinceEpoch ~/ 1000,
      'nodeId': nodeId,
      'signature': signatureHex,
    });
    return record['txId'] as String;
  }

  // Phone registry, guardian list and authority sharing (Fabric only; the
  // EVM ledger has no equivalent). Bodies are built and signed by
  // AuthorityService; these calls only carry them.

  /// Registers a phone's ID and public keys (RegisterNode).
  Future<Map<String, dynamic>> registerNode(Map<String, Object?> body) => _post('/nodes', body);

  /// A registered phone, or `found: false`.
  Future<Map<String, dynamic>> getNode(String nodeId) async =>
      await _get('/nodes/${Uri.encodeComponent(nodeId)}') as Map<String, dynamic>;

  /// A victim's guardian list on the ledger, or `found: false`.
  Future<Map<String, dynamic>> getGuardians(String victimNodeId) async =>
      await _get('/guardians/${Uri.encodeComponent(victimNodeId)}') as Map<String, dynamic>;

  /// Replaces the victim's guardian list (SetGuardians).
  Future<Map<String, dynamic>> setGuardians(Map<String, Object?> body) => _post('/guardians', body);

  /// A registered authority (name, X25519 public key, revoked flag), or `found: false`.
  Future<Map<String, dynamic>> getAuthority(String mspId) async =>
      await _get('/authorities/${Uri.encodeComponent(mspId)}') as Map<String, dynamic>;

  /// Gives an authority one sealed key piece, with the victim's consent (ShareWithAuthority).
  Future<Map<String, dynamic>> shareWithAuthority(Map<String, Object?> body) =>
      _post('/authority-shares', body);

  @override
  Future<AnchorVerificationResult> verifyEvidence(String manifestHashHex) async {
    final record = await _get('/verify/${Uri.encodeComponent(manifestHashHex)}') as Map<String, dynamic>;
    if (record['found'] != true) {
      return AnchorVerificationResult(
        found: false,
        cid: '',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(0),
        anchoredAt: DateTime.fromMillisecondsSinceEpoch(0),
        nodeId: '',
        signer: '',
        anchoredAtIsLedgerTime: false,
      );
    }
    return AnchorVerificationResult(
      found: true,
      cid: record['cid'] as String,
      capturedAt: _fromSeconds(record['capturedAt']),
      anchoredAt: _fromSeconds(record['anchoredAt']),
      anchoredAtIsLedgerTime: false,
      nodeId: record['nodeId'] as String,
      signer: record['signer'] as String,
    );
  }

  @override
  Future<AnchorBlock?> findAnchorBlock(String manifestHashHex) async {
    final record = await _get('/verify/${Uri.encodeComponent(manifestHashHex)}') as Map<String, dynamic>;
    final blockNumber = record['blockNumber'];
    if (record['found'] != true || blockNumber is! int) return null;
    return (blockNumber: blockNumber, blockTime: null);
  }

  @override
  Future<List<String>> getEvidenceHistory(String nodeId) async =>
      List<String>.from(await _get('/history/${Uri.encodeComponent(nodeId)}') as List);

  static DateTime _fromSeconds(dynamic seconds) =>
      DateTime.fromMillisecondsSinceEpoch((seconds as int) * 1000);
}
