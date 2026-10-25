// The phone and the SOS device must agree byte for byte on what they sign
// and seal when linking. The vectors come from the device code
// (device/justice_device), so a pass here means a real device accepts this
// phone's setup package and this phone accepts the device's key pieces.

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/device_link_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';

void main() {
  final v = jsonDecode(File('test/fixtures/device_link_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final owner = v['owner'] as Map<String, dynamic>;
  final device = v['device'] as Map<String, dynamic>;
  final cert = Map<String, dynamic>.from(v['certificate'] as Map);
  final setup = v['setup'] as Map<String, dynamic>;
  final piece = Map<String, dynamic>.from(v['piece'] as Map);
  const guardian = '2b50591ed9986556';

  /// The device's side of the setup seal, as device/justice_device/linking.py.
  Future<List<int>> openAsDevice(String sealedB64, String ownerX25519B64) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: await X25519().newKeyPairFromSeed(base64Decode(v['deviceX25519Private'] as String)),
      remotePublicKey: SimplePublicKey(base64Decode(ownerX25519B64), type: KeyPairType.x25519),
    );
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode('justice-chain-device-setup-v1'));
    final packed = base64Decode(sealedB64);
    return AesGcm.with256bits().decrypt(
      SecretBox(packed.sublist(28), nonce: packed.sublist(0, 12), mac: Mac(packed.sublist(12, 28))),
      secretKey: key,
    );
  }

  test('signed texts match the device code exactly', () {
    expect(DeviceLinkService.certificatePayload(cert), v['certificatePayload']);
    expect(
      DeviceLinkService.setupPayload(device['node_id'] as String, owner['nodeId'] as String, setup['issuedAt'] as int, setup['sealed'] as String),
      v['setupPayload'],
    );
    expect(
      DeviceLinkService.piecePayload(piece['manifestHash'] as String, owner['nodeId'] as String, device['node_id'] as String, guardian,
          piece['pieceHash'] as String),
      v['piecePayload'],
    );
  });

  test("a setup package this phone seals opens on the device", () async {
    final ownerKeys = await X25519().newKeyPairFromSeed(base64Decode(owner['x25519Private'] as String));
    final ownerX = base64Encode((await ownerKeys.extractPublicKey()).bytes);
    // The device's derivation opens the device code's own seal...
    final fromDevice = await openAsDevice(setup['sealed'] as String, setup['ownerX25519'] as String);
    expect(jsonDecode(utf8.decode(fromDevice)), v['setupPackage']);
    // ...and the same derivation opens what this phone seals.
    final sealed = await DeviceLinkService.sealFor(device['x25519_public_key'] as String, utf8.encode('{"hello":1}'), ownKeyPair: ownerKeys);
    expect(utf8.decode(await openAsDevice(sealed, ownerX)), '{"hello":1}');
  });

  test("the device's owner certificate checks out only against the victim's key", () async {
    final victimKey = owner['ed25519Public'] as String;
    expect(await DeviceLinkService.verifyCertificate(cert, victimNodeId: owner['nodeId'] as String, victimEd25519: victimKey), isTrue);
    expect(await DeviceLinkService.verifyCertificate(cert, victimNodeId: 'f' * 16, victimEd25519: victimKey), isFalse);
    expect(
      await DeviceLinkService.verifyCertificate({...cert, 'issuedAt': 1}, victimNodeId: owner['nodeId'] as String, victimEd25519: victimKey),
      isFalse,
    );
    expect(
      await DeviceLinkService.verifyCertificate({...cert, 'deviceEd25519': owner['ed25519Public']},
          victimNodeId: owner['nodeId'] as String, victimEd25519: victimKey),
      isFalse,
    );
  });

  test("a guardian accepts the device's piece and unseals it", () async {
    final victimKey = owner['ed25519Public'] as String;
    expect(await DeviceLinkService.verifyDevicePiece(piece, me: guardian, victimEd25519: victimKey), isTrue);
    final share = await EvidenceEncryptor.unsealGuardianShare(
      sealedShareB64: piece['sealedShare'] as String,
      ownX25519KeyPair: await X25519().newKeyPairFromSeed(base64Decode(v['guardianX25519Private'] as String)),
      senderX25519PublicKeyB64: piece['senderX25519'] as String,
    );
    expect(share.x, 1);
  });

  test('a piece for someone else, or altered on the way, is rejected', () async {
    final victimKey = owner['ed25519Public'] as String;
    expect(await DeviceLinkService.verifyDevicePiece(piece, me: 'a' * 16, victimEd25519: victimKey), isFalse);
    final other = base64Encode(List<int>.filled(61, 7));
    expect(await DeviceLinkService.verifyDevicePiece({...piece, 'sealedShare': other}, me: guardian, victimEd25519: victimKey), isFalse);
    expect(
      await DeviceLinkService.verifyDevicePiece({...piece, 'senderX25519': device['public_key']}, me: guardian, victimEd25519: victimKey),
      isFalse,
    );
  });
}
