import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../logic/guardian_manager.dart';
import 'authority_service.dart';
import 'identity_service.dart';

/// The user's SOS device (the Raspberry Pi in device/), linked to this phone.
///
/// Linking: the user scans the device's QR (the app's pairing-QR fields plus
/// "kind": "sos-device"). This phone signs an owner certificate ("this
/// device is mine") and leaves the device a setup package at the gateway:
/// who she is, her guardians and the certificate, sealed so only the device
/// can read it. The package is sent again whenever the app starts, so the
/// device picks up guardian changes.
///
/// Guardians: the device leaves each guardian their key piece of a clip in
/// the gateway mailbox. A guardian's phone trusts the device's keys only
/// through the certificate, checked against the victim's key saved when
/// they paired.
///
/// Signed texts (Ed25519 over UTF-8), mirrored in device/justice_device/linking.py
/// and fabric/gateway/device.js.
class DeviceLinkService {
  DeviceLinkService._();

  static Box get _vault => Hive.box('vault_box');
  static const String _deviceKey = 'sos_device';
  static const String _setupInfo = 'justice-chain-device-setup-v1';

  static bool isDeviceQr(Object? data) => data is Map && data['kind'] == 'sos-device';

  /// The linked device ({nodeId, ed25519, x25519, anchoringAddress, linkedAt,
  /// lastSentAt}), or null.
  static Map? linkedDevice() => _vault.get(_deviceKey) as Map?;

  @visibleForTesting
  static String certificatePayload(Map cert) => [
        'justice-chain/device-owner/v1',
        cert['deviceNodeId'],
        cert['deviceEd25519'],
        cert['deviceX25519'],
        (cert['deviceAnchoringAddress'] as String).toLowerCase(),
        cert['ownerNodeId'],
        '${cert['issuedAt']}',
      ].join('|');

  @visibleForTesting
  static String setupPayload(String device, String owner, int issuedAt, String sealedB64) =>
      'justice-chain/device-setup/v1|$device|$owner|$issuedAt|${crypto.sha256.convert(base64Decode(sealedB64))}';

  @visibleForTesting
  static String piecePayload(String manifestHash, String owner, String device, String guardian, String pieceHash) =>
      'justice-chain/device-piece/v1|$manifestHash|$owner|$device|$guardian|$pieceHash';

  static String _nodeIdOf(String ed25519B64) => crypto.sha256.convert(base64Decode(ed25519B64)).toString().substring(0, 16);

  /// Links the device from its scanned QR and sends it its first setup package.
  static Future<void> link(Map qr) async {
    final nodeId = qr['node_id'] as String;
    final ed = qr['public_key'] as String;
    if (_nodeIdOf(ed) != nodeId || qr['x25519_public_key'] == null || qr['anchoring_address'] == null) {
      throw ArgumentError("This QR code isn't a valid SOS device code");
    }
    await _vault.put(_deviceKey, {
      'nodeId': nodeId,
      'ed25519': ed,
      'x25519': qr['x25519_public_key'],
      'anchoringAddress': (qr['anchoring_address'] as String).toLowerCase(),
      'linkedAt': DateTime.now().toIso8601String(),
    });
    await sendSetup();
  }

  static Future<void> unlink() => _vault.delete(_deviceKey);

  /// Leaves the linked device a fresh setup package. No-op when none is linked.
  static Future<void> sendSetup() async {
    final device = linkedDevice();
    if (device == null) return;
    final me = jsonDecode(await IdentityService.getQrPayload()) as Map;
    final ownerNodeId = me['node_id'] as String;
    final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final cert = <String, Object>{
      'deviceNodeId': device['nodeId'] as String,
      'deviceEd25519': device['ed25519'] as String,
      'deviceX25519': device['x25519'] as String,
      'deviceAnchoringAddress': device['anchoringAddress'] as String,
      'ownerNodeId': ownerNodeId,
      'issuedAt': issuedAt,
    };
    cert['signature'] = await IdentityService.signBytes(utf8.encode(certificatePayload(cert)));

    final package = {
      'owner': {
        'nodeId': ownerNodeId,
        'username': await IdentityService.getMyName(),
        'ed25519Public': me['public_key'],
        'x25519Public': me['x25519_public_key'],
      },
      'guardians': [
        for (final entry in GuardianManager.getTrustedGuardians().entries)
          if (entry.value is Map && entry.value['x25519_public_key'] != null)
            {'nodeId': entry.key, 'name': entry.value['name'] ?? '', 'x25519Public': entry.value['x25519_public_key']},
      ],
      'certificate': cert,
      'allowSingleGuardian': GuardianManager.allowSingleGuardian,
      'issuedAt': issuedAt,
    };
    final sealed = await sealFor(device['x25519'] as String, utf8.encode(jsonEncode(package)));

    await AuthorityService.requireGateway().putDeviceSetup(device['nodeId'] as String, {
      'ownerNodeId': ownerNodeId,
      'ownerEd25519': me['public_key'],
      'ownerX25519': me['x25519_public_key'],
      'issuedAt': issuedAt,
      'sealed': sealed,
      'signature': await IdentityService.signBytes(utf8.encode(setupPayload(device['nodeId'] as String, ownerNodeId, issuedAt, sealed))),
    });
    await _vault.put(_deviceKey, Map<String, dynamic>.from(device)..['lastSentAt'] = DateTime.now().toIso8601String());
    developer.log('Sent setup package to SOS device ${device['nodeId']}', name: 'JusticeChain.Device');
  }

  /// Seals [bytes] for the device: X25519 with this phone's key, HKDF, then
  /// AES-GCM packed as nonce + MAC + ciphertext (the app's box format).
  static Future<String> sealFor(String recipientX25519B64, List<int> bytes, {SimpleKeyPair? ownKeyPair}) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: ownKeyPair ?? await IdentityService.getX25519KeyPair(),
      remotePublicKey: SimplePublicKey(base64Decode(recipientX25519B64), type: KeyPairType.x25519),
    );
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, info: utf8.encode(_setupInfo));
    final box = await AesGcm.with256bits().encrypt(bytes, secretKey: key);
    return base64Encode([...box.nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  static Future<bool> _verify(String publicKeyB64, String text, String? signatureB64) async {
    if (signatureB64 == null) return false;
    try {
      return await Ed25519().verify(
        utf8.encode(text),
        signature: Signature(base64Decode(signatureB64), publicKey: SimplePublicKey(base64Decode(publicKeyB64), type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Whether [cert] is the victim's signed word that this device is hers.
  static Future<bool> verifyCertificate(Map cert, {required String victimNodeId, required String victimEd25519}) async {
    final ed = cert['deviceEd25519'];
    if (cert['ownerNodeId'] != victimNodeId || ed is! String || cert['deviceAnchoringAddress'] is! String) return false;
    try {
      if (_nodeIdOf(ed) != cert['deviceNodeId']) return false;
    } catch (_) {
      return false;
    }
    return _verify(victimEd25519, certificatePayload(cert), cert['signature'] as String?);
  }

  /// Checks a device-piece envelope from the mailbox: certified by the
  /// victim, sent by that device, addressed to [me], piece unaltered.
  static Future<bool> verifyDevicePiece(Map env, {required String me, required String victimEd25519}) async {
    final cert = env['certificate'];
    final victim = env['victimNodeId'];
    final sealed = env['sealedShare'];
    if (cert is! Map || victim is! String || sealed is! String || env['toNodeId'] != me) return false;
    if (!await verifyCertificate(cert, victimNodeId: victim, victimEd25519: victimEd25519)) return false;
    if (env['fromNodeId'] != cert['deviceNodeId'] || env['senderX25519'] != cert['deviceX25519']) return false;
    final pieceHash = crypto.sha256.convert(base64Decode(sealed)).toString();
    if (pieceHash != env['pieceHash']) return false;
    return _verify(
      cert['deviceEd25519'] as String,
      piecePayload(env['manifestHash'] as String, victim, env['fromNodeId'] as String, me, pieceHash),
      env['signature'] as String?,
    );
  }
}
