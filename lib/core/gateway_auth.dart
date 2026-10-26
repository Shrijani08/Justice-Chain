import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'identity_service.dart';

/// Headers that prove a gateway request comes from this phone: its node ID,
/// the time, and an Ed25519 signature with its registered key over
/// `justice-chain/request/v1|METHOD|path|timestamp|sha256(body)`. Mirrors
/// fabric/gateway/auth.js. Replaces the shared API key, which used to ship
/// inside every APK (judge review finding S1).
typedef RequestSigner = Future<Map<String, String>> Function(String method, String path, List<int> body);

class GatewayAuth {
  GatewayAuth._();

  static String payload(String method, String path, int timestamp, List<int> body) =>
      'justice-chain/request/v1|$method|$path|$timestamp|${crypto.sha256.convert(body)}';

  /// Signs with this phone's identity key.
  static Future<Map<String, String>> sign(String method, String path, List<int> body) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'X-Node-Id': await IdentityService.getMyNodeId(),
      'X-Timestamp': '$timestamp',
      'X-Signature': await IdentityService.signBytes(utf8.encode(payload(method, path, timestamp, body))),
    };
  }
}
