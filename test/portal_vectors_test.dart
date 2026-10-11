import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';

// Sample outputs from the app's own code for the officer portal, which
// must open them exactly (fabric/portal/test/portal.test.js): a clip
// encrypted with encryptAndSeal, pieces 1-3 sealed to a test evidence desk
// key at "recording", and a late piece 4 from issueGuardianShare (the
// victim's release path), all from a 2-of-n key.
//
// Written on the first run, or when JC_WRITE_PORTAL_VECTORS is set; every
// other run re-opens the saved file with the current app code, so a format
// change fails here before it silently breaks the portal.
const _vectorsPath = 'fabric/portal/test/app_vectors.json';

List<int> _fixedBytes(int length, int seed) => List<int>.generate(length, (i) => (seed * 37 + i * 11) & 0xff);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final deskSeed = _fixedBytes(32, 7);

  Future<SimpleKeyPair> deskKeyPair() => X25519().newKeyPairFromSeed(deskSeed);

  Future<Map<String, dynamic>> generate() async {
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
    final victimX25519 = (await (await IdentityService.getX25519KeyPair()).extractPublicKey()).bytes;
    final deskPublic = base64Encode((await (await deskKeyPair()).extractPublicKey()).bytes);
    final plaintext = Uint8List.fromList(_fixedBytes(4000, 3));

    final dir = await Directory.systemTemp.createTemp('portal_vectors');
    try {
      final clipPath = '${dir.path}/clip.mp4';
      await File(clipPath).writeAsBytes(plaintext);
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        clipPath,
        guardians: [
          for (var i = 1; i <= 3; i++) (nodeId: 'desk-piece-$i', x25519PublicKeyB64: deskPublic),
        ],
        threshold: 2,
      );
      final latePiece = await EvidenceEncryptor.issueGuardianShare(
        wrappedKeyB64: sealed.wrappedKeyB64,
        x: sealed.nextShareX,
        guardianX25519PublicKeyB64: deskPublic,
        threshold: 2,
      );
      return {
        'description': 'Officer-portal vectors from the Justice-Chain app (test keys only). '
            'Regenerate with JC_WRITE_PORTAL_VECTORS=1 flutter test test/portal_vectors_test.dart',
        'deskPrivateSeed': base64Encode(deskSeed),
        'victimX25519Public': base64Encode(victimX25519),
        'threshold': 2,
        'plaintext': base64Encode(plaintext),
        'plaintextHash': sealed.plaintextHash,
        'ciphertext': base64Encode(await File(sealed.cipherPath).readAsBytes()),
        'pieces': [
          for (var i = 1; i <= 3; i++) {'x': i, 'sealedShare': sealed.guardianShares['desk-piece-$i']},
          {'x': sealed.nextShareX, 'sealedShare': latePiece},
        ],
      };
    } finally {
      await dir.delete(recursive: true);
    }
  }

  test('saved portal vectors still open with the current app code', () async {
    final file = File(_vectorsPath);
    if (Platform.environment.containsKey('JC_WRITE_PORTAL_VECTORS') || !file.existsSync()) {
      await file.parent.create(recursive: true);
      await file.writeAsString('${const JsonEncoder.withIndent('  ').convert(await generate())}\n');
    }

    final vectors = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final pieces = (vectors['pieces'] as List).cast<Map<String, dynamic>>();
    expect(pieces.map((p) => p['x']), [1, 2, 3, 4]);

    // The desk opens the late piece and an original one, as an officer would.
    final shares = [
      for (final piece in [pieces[3], pieces[0]])
        await EvidenceEncryptor.unsealGuardianShare(
          sealedShareB64: piece['sealedShare'] as String,
          ownX25519KeyPair: await deskKeyPair(),
          senderX25519PublicKeyB64: vectors['victimX25519Public'] as String,
        ),
    ];
    final dir = await Directory.systemTemp.createTemp('portal_vectors_check');
    try {
      final cipherPath = '${dir.path}/clip.mp4.enc';
      await File(cipherPath).writeAsBytes(base64Decode(vectors['ciphertext'] as String));
      final opened = await EvidenceEncryptor.decryptFileWithShares(
        cipherPath: cipherPath,
        shares: shares,
        threshold: vectors['threshold'] as int,
      );
      expect(opened, base64Decode(vectors['plaintext'] as String));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
