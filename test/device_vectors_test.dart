import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:web3dart/web3dart.dart';

// Sample outputs ("test vectors") from the app's own sealing code, made with
// fixed test keys. The SOS device (device/, Python) must open these exactly
// as a guardian's phone would; device/tests/test_app_vectors.py checks that.
//
// The file is written on the first run, or whenever JC_WRITE_DEVICE_VECTORS
// is set. On every other run this test re-opens the saved vectors with the
// current app code, so a change to the app's formats fails here first instead
// of silently breaking the device.
const _vectorsPath = 'device/tests/vectors/app_vectors.json';

List<int> _fixedBytes(int length, int seed) =>
    List<int>.generate(length, (i) => (seed * 31 + i * 7) & 0xff);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final victimEd25519Seed = _fixedBytes(32, 1);
  final victimX25519Seed = _fixedBytes(32, 2);
  const victimAnchoringKeyHex =
      '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318';
  final guardianSeeds = [_fixedBytes(32, 3), _fixedBytes(32, 4), _fixedBytes(32, 5)];

  Future<Map<String, String>> victimStorage() async {
    final ed = await Ed25519().newKeyPairFromSeed(victimEd25519Seed);
    final edPublic = (await ed.extractPublicKey()).bytes;
    final x = await X25519().newKeyPairFromSeed(victimX25519Seed);
    final xPublic = (await x.extractPublicKey()).bytes;
    return {
      'private_key': base64Encode(victimEd25519Seed),
      'raw_public_key': base64Encode(edPublic),
      'public_node_id': crypto.sha256.convert(edPublic).toString().substring(0, 16),
      'x25519_private_key': base64Encode(victimX25519Seed),
      'raw_x25519_public_key': base64Encode(xPublic),
      'anchoring_private_key': victimAnchoringKeyHex,
    };
  }

  Future<List<Map<String, String>>> guardianKeys() async => [
        for (final seed in guardianSeeds)
          await () async {
            final pair = await X25519().newKeyPairFromSeed(seed);
            final public = (await pair.extractPublicKey()).bytes;
            return {
              'nodeId': crypto.sha256.convert(public).toString().substring(0, 16),
              'x25519Private': base64Encode(seed),
              'x25519Public': base64Encode(public),
            };
          }(),
      ];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(await victimStorage());
    IdentityService.resetCacheForTest();
  });

  Future<Map<String, dynamic>> generate() async {
    final storage = await victimStorage();
    final guardians = await guardianKeys();
    final plaintext = Uint8List.fromList(_fixedBytes(1500, 9));

    final dir = await Directory.systemTemp.createTemp('device_vectors');
    try {
      final clipPath = '${dir.path}/clip.mp4';
      await File(clipPath).writeAsBytes(plaintext);
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        clipPath,
        guardians: [
          for (final g in guardians)
            (nodeId: g['nodeId']!, x25519PublicKeyB64: g['x25519Public']!),
        ],
        threshold: 2,
      );

      return {
        'description': 'Sealing outputs from the Justice-Chain app with fixed test keys. '
            'Regenerate with JC_WRITE_DEVICE_VECTORS=1 flutter test test/device_vectors_test.dart',
        'victim': {
          'ed25519Seed': storage['private_key'],
          'ed25519Public': storage['raw_public_key'],
          'nodeId': storage['public_node_id'],
          'x25519Private': storage['x25519_private_key'],
          'x25519Public': storage['raw_x25519_public_key'],
          'anchoringPrivateKey': victimAnchoringKeyHex,
          'anchoringAddress':
              EthPrivateKey.fromHex(victimAnchoringKeyHex).address.eip55With0x,
        },
        'guardians': guardians,
        'clip': {
          'plaintext': base64Encode(plaintext),
          'plaintextHash': sealed.plaintextHash,
          'ciphertext': base64Encode(await File(sealed.cipherPath).readAsBytes()),
          'signature': sealed.signatureB64,
          'anchorSignature': await AnchoringService.signAnchor(sealed.plaintextHash),
          'threshold': sealed.threshold,
          'guardianShares': sealed.guardianShares,
        },
      };
    } finally {
      await dir.delete(recursive: true);
    }
  }

  test('saved device vectors still open with the current app code', () async {
    final file = File(_vectorsPath);
    if (Platform.environment.containsKey('JC_WRITE_DEVICE_VECTORS') || !file.existsSync()) {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(await generate())}\n',
      );
    }

    final vectors = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final victim = vectors['victim'] as Map<String, dynamic>;
    final clip = vectors['clip'] as Map<String, dynamic>;
    final guardians = (vectors['guardians'] as List).cast<Map<String, dynamic>>();
    final plaintext = base64Decode(clip['plaintext'] as String);

    // Two guardians unseal their shares and rebuild the key, as on a phone.
    final shares = [
      for (final g in guardians.take(2))
        await EvidenceEncryptor.unsealGuardianShare(
          sealedShareB64: (clip['guardianShares'] as Map)[g['nodeId']] as String,
          ownX25519KeyPair:
              await X25519().newKeyPairFromSeed(base64Decode(g['x25519Private'] as String)),
          senderX25519PublicKeyB64: victim['x25519Public'] as String,
        ),
    ];
    final dir = await Directory.systemTemp.createTemp('device_vectors_check');
    try {
      final cipherPath = '${dir.path}/clip.mp4.enc';
      await File(cipherPath).writeAsBytes(base64Decode(clip['ciphertext'] as String));
      final opened = await EvidenceEncryptor.decryptFileWithShares(
        cipherPath: cipherPath,
        shares: shares,
        threshold: clip['threshold'] as int,
      );
      expect(opened, plaintext);
    } finally {
      await dir.delete(recursive: true);
    }

    expect(crypto.sha256.convert(plaintext).toString(), clip['plaintextHash']);

    final signatureOk = await Ed25519().verify(
      utf8.encode(clip['plaintextHash'] as String),
      signature: Signature(
        base64Decode(clip['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(victim['ed25519Public'] as String),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    expect(signatureOk, isTrue);

    // Anchor signatures are deterministic (RFC 6979), so this one must not drift.
    expect(
      await AnchoringService.signAnchor(clip['plaintextHash'] as String),
      clip['anchorSignature'],
    );
  });
}
