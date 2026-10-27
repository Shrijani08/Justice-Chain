import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/co_guardian_service.dart';
import 'package:justice_chain/core/device_link_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/core/shamir.dart';
import 'package:web3dart/web3dart.dart';

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

String _registerPayload(Map r) =>
    'justice-chain/register-node/v1|${r['nodeId']}|${r['ed25519PublicKey']}|${r['x25519PublicKey']}|${r['anchoringAddress']}';

/// Another phone, signing the way the app does: Ed25519 over the payload's
/// bytes, and EIP-191 over the 32 raw bytes of its SHA-256.
class _Phone {
  _Phone._(this._ed, this.edPub, this.xPub, this._eth, this.nodeId);

  final SimpleKeyPair _ed;
  final String edPub;
  final String xPub;
  final EthPrivateKey _eth;
  final String nodeId;

  String get address => '0x${_eth.address.toString().toLowerCase().replaceFirst('0x', '')}';

  static Future<_Phone> create() async {
    final ed = await Ed25519().newKeyPair();
    final edPub = base64Encode((await ed.extractPublicKey()).bytes);
    final xPub = base64Encode((await (await X25519().newKeyPair()).extractPublicKey()).bytes);
    return _Phone._(ed, edPub, xPub, EthPrivateKey.createRandom(Random.secure()),
        _sha256Hex(base64Decode(edPub)).substring(0, 16));
  }

  Future<String> edSign(String payload) async =>
      base64Encode((await Ed25519().sign(utf8.encode(payload), keyPair: _ed)).bytes);

  String sign(String payload) => bytesToHex(
      _eth.signPersonalMessageToUint8List(Uint8List.fromList(crypto.sha256.convert(utf8.encode(payload)).bytes)));

  Future<Map<String, dynamic>> record() async {
    final r = {'nodeId': nodeId, 'ed25519PublicKey': edPub, 'x25519PublicKey': xPub, 'anchoringAddress': address};
    return {...r, 'ed25519Signature': await edSign(_registerPayload(r))};
  }

  /// The guardian list this phone (as victim) signs for the ledger.
  Map<String, dynamic> guardianList(List<String> ids, int sequence) {
    final sorted = [...ids]..sort();
    return {
      'found': true,
      'victimNodeId': nodeId,
      'guardians': sorted,
      'sequence': sequence,
      'signature': sign('justice-chain/set-guardians/v1|$nodeId|$sequence|${sorted.join(',')}'),
    };
  }
}

/// The gateway's node, guardian and mailbox routes.
class _FakeGateway {
  final nodes = <String, Map<String, dynamic>>{};
  final guardians = <String, Map<String, dynamic>>{};
  final mailbox = <String, List<Map<String, dynamic>>>{};
  final posts = <String, List<Map<String, dynamic>>>{};
  bool down = false;
  bool failNextForward = false;

  http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request r) async {
    if (down) return _json({'error': 'Fabric network unavailable'}, 503);
    final parts = r.url.path.split('/').where((p) => p.isNotEmpty).toList();
    if (r.method == 'GET') {
      final id = parts[1];
      switch (parts.first) {
        case 'nodes':
          return _json(nodes[id] == null ? {'found': false, 'nodeId': id} : {'found': true, ...nodes[id]!});
        case 'guardians':
          return _json(guardians[id] ?? {'found': false, 'victimNodeId': id});
        case 'pieces':
          return _json(mailbox[id] ?? []);
      }
      return _json({'error': 'Not found'}, 404);
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    posts.putIfAbsent(r.url.path, () => []).add(body);
    if (r.url.path == '/pieces') {
      if (failNextForward) {
        failNextForward = false;
        return _json({'error': 'Fabric network unavailable'}, 503);
      }
      final env = {
        ...body,
        'id': _sha256Hex(utf8.encode('${body['manifestHash']}|${body['toNodeId']}')).substring(0, 32),
        'pieceHash': _sha256Hex(base64Decode(body['sealedShare'] as String)),
      };
      mailbox.putIfAbsent(body['toNodeId'] as String, () => []).add(env);
      return _json(env);
    }
    if (parts.first == 'pieces' && parts.last == 'ack') {
      final ids = (body['ids'] as List).cast<String>();
      mailbox[parts[1]]?.removeWhere((e) => ids.contains(e['id']));
      return _json({'deleted': ids.length});
    }
    return _json({'error': 'Not found'}, 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const clip = 'c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1';
  late Directory tempDir;
  late Box vault;
  late _FakeGateway gateway;
  late _Phone victim;
  late _Phone coGuardian;
  late String me;
  late Map<String, dynamic> myRecord;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('co_guardian_test');
    Hive.init(tempDir.path);
    vault = await Hive.openBox('vault_box');
    await Hive.openBox(OutboxService.boxName);
    await Hive.openBox(MeshService.receivedSharesBoxName);
    OutboxService.manageAdvertising = false;
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();

    final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
    me = qr['node_id'] as String;
    final mine = {
      'nodeId': me,
      'ed25519PublicKey': qr['public_key'],
      'x25519PublicKey': qr['x25519_public_key'],
      'anchoringAddress': (qr['anchoring_address'] as String).toLowerCase(),
    };
    myRecord = {...mine, 'ed25519Signature': await IdentityService.signBytes(utf8.encode(_registerPayload(mine)))};

    victim = await _Phone.create();
    coGuardian = await _Phone.create();
    gateway = _FakeGateway()
      ..nodes[me] = myRecord
      ..nodes[victim.nodeId] = await victim.record()
      ..nodes[coGuardian.nodeId] = await coGuardian.record()
      ..guardians[victim.nodeId] = victim.guardianList([me, coGuardian.nodeId], 3);
    AuthorityService.gatewayForTest = FabricLedgerService(gatewayUrl: 'http://gw', client: MockClient(gateway.handle));

    // This phone paired with the victim only, never with the co-guardian.
    await vault.put('trusted_guardians', {
      victim.nodeId: {
        'name': 'Asha',
        'public_key': victim.edPub,
        'x25519_public_key': victim.xPub,
        'anchoring_address': victim.address,
      },
    });
  });

  tearDown(() async {
    AuthorityService.gatewayForTest = null;
    OutboxService.manageAdvertising = true;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('checking ledger records on the phone', () {
    test('recovers the signer of the cross-language anchor vector', () {
      // The same values as test/anchor_signature_vector_test.dart and the chaincode tests.
      expect(
        CoGuardianService.recoverHashSigner(
          '53f7a63576d0deb96daa84ac541364d061f43190d2a7a4204eeef6ffa49d290e',
          '727f98f85eb303756a58d66cd6b6195dd812b7a221b760917525ee9b96ea0dd8'
              '4f111e799e0079f6af1cbed11bfb856d5f7bfc3f110c251dd1dd5c124261d14c1b',
        ),
        '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
      );
      expect(CoGuardianService.recoverHashSigner('00' * 32, 'zz'), isNull);
    });

    test('a node record must have an ID derived from its key and a signature covering every key', () async {
      final good = await coGuardian.record();
      expect(await CoGuardianService.verifyNodeRecord(good), isTrue);
      expect(await CoGuardianService.verifyNodeRecord(myRecord), isTrue);

      final other = await _Phone.create();
      // The gateway swaps in its own encryption key, or another phone's ID, or drops the signature.
      expect(await CoGuardianService.verifyNodeRecord({...good, 'x25519PublicKey': other.xPub}), isFalse);
      expect(await CoGuardianService.verifyNodeRecord({...good, 'nodeId': other.nodeId}), isFalse);
      expect(await CoGuardianService.verifyNodeRecord({...good}..remove('ed25519Signature')), isFalse);
    });

    Future<List<String>> check(Map<String, dynamic> list, {Map? paired, int? lastSequence, Map? victimRecord}) async =>
        CoGuardianService.verifyGuardianList(
          victimRecord: victimRecord ?? await victim.record(),
          list: list,
          pairedVictim: paired ?? vault.get('trusted_guardians')[victim.nodeId] as Map,
          lastSequence: lastSequence,
        );

    test("accepts the victim's signed list", () async {
      expect(await check(victim.guardianList([coGuardian.nodeId, me], 3)), ([me, coGuardian.nodeId]..sort()));
    });

    test("refuses a list the victim didn't sign, or that was changed after signing", () async {
      final stranger = await _Phone.create();
      final forged = {
        ...victim.guardianList([me], 4),
        'signature': stranger.sign('justice-chain/set-guardians/v1|${victim.nodeId}|4|$me'),
      };
      await expectLater(check(forged), throwsA(isA<UntrustedLedgerRecord>()));

      final tampered = {...victim.guardianList([me], 4), 'guardians': [me, stranger.nodeId]..sort()};
      await expectLater(check(tampered), throwsA(isA<UntrustedLedgerRecord>()));

      final unsigned = {...victim.guardianList([me], 4)}..remove('signature');
      await expectLater(check(unsigned), throwsA(isA<UntrustedLedgerRecord>()));
    });

    test('refuses an older list than one already seen (a replay)', () async {
      await expectLater(check(victim.guardianList([me, coGuardian.nodeId], 2), lastSequence: 3),
          throwsA(isA<UntrustedLedgerRecord>()));
    });

    test("refuses a victim record whose keys aren't the ones saved at pairing", () async {
      final impostor = await _Phone.create();
      // The gateway answers with another phone's record and a list it signed.
      final fakeVictim = {...await impostor.record(), 'nodeId': victim.nodeId};
      await expectLater(check(impostor.guardianList([me], 9), victimRecord: fakeVictim),
          throwsA(isA<UntrustedLedgerRecord>()));
      final realKeysOtherAddress = {
        ...vault.get('trusted_guardians')[victim.nodeId] as Map,
        'anchoring_address': impostor.address,
      };
      await expectLater(check(victim.guardianList([me], 3), paired: realKeysOtherAddress),
          throwsA(isA<UntrustedLedgerRecord>()));
    });

    test('lists the co-guardian this phone never paired with, by short ID', () async {
      final found = await CoGuardianService.coGuardiansOf(victim.nodeId);
      expect(found.map((g) => g.nodeId), [coGuardian.nodeId]);
      expect(found.single.x25519PublicKey, coGuardian.xPub);
      expect(found.single.label, startsWith('Guardian ${coGuardian.nodeId.substring(0, 4)}'));

      // A later, smaller list replayed by the gateway is refused.
      gateway.guardians[victim.nodeId] = victim.guardianList([me], 2);
      await expectLater(CoGuardianService.coGuardiansOf(victim.nodeId), throwsA(isA<UntrustedLedgerRecord>()));
    });
  });

  group('the mailbox', () {
    Future<ShamirShare> givePiece() async {
      // The victim's piece for this phone (sealed with this phone's own key
      // as sender in the test; key agreement is symmetric).
      final piece = (x: 1, y: Uint8List.fromList(List.generate(32, (i) => i)));
      await Hive.box(MeshService.receivedSharesBoxName).put('$clip:${victim.nodeId}', {
        'manifestHash': clip,
        'victimNodeId': victim.nodeId,
        'senderNodeId': victim.nodeId,
        'senderX25519': myRecord['x25519PublicKey'],
        'sealedShare': await EvidenceEncryptor.sealShare(piece, myRecord['x25519PublicKey'] as String),
        'signature': 'victim-device-signature',
        'quorum': 2,
        'cid': 'bafyclip',
      });
      return piece;
    }

    test('sends a piece sealed to the co-guardian and signed by this phone; a retry sends the same piece', () async {
      final piece = await givePiece();
      gateway.failNextForward = true;
      await expectLater(CoGuardianService.forwardViaMailbox(clip, coGuardian.nodeId), throwsA(anything));
      await CoGuardianService.forwardViaMailbox(clip, coGuardian.nodeId);

      final sent = gateway.posts['/pieces']!;
      expect(sent, hasLength(2));
      expect(sent[1]['sealedShare'], sent[0]['sealedShare']);
      final body = sent.last;
      expect(body['fromNodeId'], me);
      expect(body['toNodeId'], coGuardian.nodeId);
      expect((body['share'] as Map)['cid'], 'bafyclip');
      expect((body['share'] as Map).containsKey('sealedShare'), isFalse);

      final pieceHash = _sha256Hex(base64Decode(body['sealedShare'] as String));
      final signed = await Ed25519().verify(
        utf8.encode(CoGuardianService.forwardPayload(clip, victim.nodeId, me, coGuardian.nodeId, pieceHash)),
        signature: Signature(base64Decode(body['signature'] as String),
            publicKey: SimplePublicKey(base64Decode(myRecord['ed25519PublicKey'] as String), type: KeyPairType.ed25519)),
      );
      expect(signed, isTrue);
      expect(CoGuardianService.forwardSent(clip, coGuardian.nodeId), isTrue);

      // Only the co-guardian's key opens it: re-sealed to their X25519 key, so
      // this phone (with the co-guardian's public key as the other side) can
      // derive the same key, and anyone else can't.
      final again = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: body['sealedShare'] as String,
        ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
        senderX25519PublicKeyB64: coGuardian.xPub,
      );
      expect(again.x, piece.x);
      expect(again.y, piece.y);
    });

    test('refuses to send to someone who is not on the victim\'s list', () async {
      await givePiece();
      final stranger = await _Phone.create();
      gateway.nodes[stranger.nodeId] = await stranger.record();
      await expectLater(CoGuardianService.forwardViaMailbox(clip, stranger.nodeId), throwsA(isA<StateError>()));
      expect(gateway.posts['/pieces'], isNull);
    });

    Future<Map<String, dynamic>> envelopeFrom(_Phone sender, {_Phone? signer}) async {
      final piece = (x: 2, y: Uint8List.fromList(List.filled(32, 7)));
      // Sealed between the sender and this phone (symmetric key agreement).
      final sealed = await EvidenceEncryptor.sealShare(piece, sender.xPub);
      final pieceHash = _sha256Hex(base64Decode(sealed));
      return {
        'id': _sha256Hex(utf8.encode('${sender.nodeId}$pieceHash')).substring(0, 32),
        'manifestHash': clip,
        'victimNodeId': victim.nodeId,
        'fromNodeId': sender.nodeId,
        'toNodeId': me,
        'pieceHash': pieceHash,
        'sealedShare': sealed,
        'senderX25519': sender.xPub,
        'signature': await (signer ?? sender)
            .edSign(CoGuardianService.forwardPayload(clip, victim.nodeId, sender.nodeId, me, pieceHash)),
        'share': {'cid': 'bafyclip', 'quorum': 2, 'signature': 'victim-device-signature'},
      };
    }

    test("stores a co-guardian's checked piece as a forwarded piece, then clears it", () async {
      gateway.mailbox[me] = [await envelopeFrom(coGuardian)];
      expect(await CoGuardianService.fetchMailbox(), 1);

      final stored = Hive.box(MeshService.receivedSharesBoxName).get('$clip:fwd:${coGuardian.nodeId}') as Map;
      expect(stored['forwardedBy'], coGuardian.nodeId);
      expect(stored['senderX25519'], coGuardian.xPub);
      expect(stored['cid'], 'bafyclip');
      final opened = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: stored['sealedShare'] as String,
        ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
        senderX25519PublicKeyB64: stored['senderX25519'] as String,
      );
      expect(opened.x, 2);
      expect(gateway.mailbox[me], isEmpty);

      final ack = gateway.posts['/pieces/$me/ack']!.single;
      final ackOk = await Ed25519().verify(
        utf8.encode('justice-chain/ack-pieces/v1|$me|${(ack['ids'] as List).join(',')}'),
        signature: Signature(base64Decode(ack['signature'] as String),
            publicKey: SimplePublicKey(base64Decode(myRecord['ed25519PublicKey'] as String), type: KeyPairType.ed25519)),
      );
      expect(ackOk, isTrue);
    });

    test('drops forged pieces: from a stranger, signed by someone else, or with a swapped key', () async {
      final stranger = await _Phone.create();
      gateway.nodes[stranger.nodeId] = await stranger.record();
      final swapped = {...await envelopeFrom(coGuardian), 'id': 'f' * 32, 'senderX25519': stranger.xPub};
      gateway.mailbox[me] = [
        await envelopeFrom(stranger),
        {...await envelopeFrom(coGuardian, signer: stranger), 'id': 'e' * 32},
        swapped,
      ];
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(Hive.box(MeshService.receivedSharesBoxName).isEmpty, isTrue);
      expect(gateway.mailbox[me], isEmpty); // cleared, so they aren't fetched forever
    });

    test('keeps pieces it could not check while the ledger is unreachable', () async {
      gateway.mailbox[me] = [await envelopeFrom(coGuardian)];
      final env = gateway.mailbox[me]!.single;
      // The mailbox answers, then the gateway goes down before the checks.
      var calls = 0;
      AuthorityService.gatewayForTest = FabricLedgerService(
        gatewayUrl: 'http://gw',
        client: MockClient((r) async => ++calls == 1 ? gateway.handle(r) : http.Response('{"error":"down"}', 503)),
      );
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(gateway.mailbox[me], [env]);
      expect(gateway.posts['/pieces/$me/ack'], isNull);
    });
  });

  group('pieces from an SOS device', () {
    /// A device piece for this phone, from a device [owner] certified as hers.
    Future<Map<String, dynamic>> devicePiece({required _Phone owner, String id = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0'}) async {
      final device = await _Phone.create();
      final cert = <String, Object>{
        'deviceNodeId': device.nodeId,
        'deviceEd25519': device.edPub,
        'deviceX25519': device.xPub,
        'deviceAnchoringAddress': device.address,
        'ownerNodeId': victim.nodeId,
        'issuedAt': 1792900000,
      };
      cert['signature'] = await owner.edSign(DeviceLinkService.certificatePayload(cert));
      final sealed = base64Encode(List<int>.generate(61, (i) => i));
      final pieceHash = _sha256Hex(base64Decode(sealed));
      return {
        'id': id,
        'kind': 'device',
        'manifestHash': clip,
        'victimNodeId': victim.nodeId,
        'fromNodeId': device.nodeId,
        'toNodeId': me,
        'sealedShare': sealed,
        'pieceHash': pieceHash,
        'senderX25519': device.xPub,
        'signature': await device.edSign(DeviceLinkService.piecePayload(clip, victim.nodeId, device.nodeId, me, pieceHash)),
        'certificate': cert,
        'share': {'cid': 'bafydevice', 'quorum': 2, 'signature': 'device-signature', 'source': 'sos-device'},
      };
    }

    test("stores a piece from the victim's certified device as this phone's own piece", () async {
      final env = await devicePiece(owner: victim);
      gateway.mailbox[me] = [env];
      expect(await CoGuardianService.fetchMailbox(), 1);

      final stored = Hive.box(MeshService.receivedSharesBoxName).get('$clip:dev:${env['fromNodeId']}') as Map;
      expect(stored['forwardedBy'], isNull); // so it can be passed on to a co-guardian
      expect(stored['victimNodeId'], victim.nodeId);
      expect(stored['senderX25519'], env['senderX25519']);
      expect((stored['deviceCertificate'] as Map)['deviceNodeId'], env['fromNodeId']);
      expect(stored['cid'], 'bafydevice');
      expect(gateway.mailbox[me], isEmpty);
    });

    test('keeps a device piece in the mailbox until this phone pairs with its owner', () async {
      await vault.put('trusted_guardians', <String, dynamic>{});
      final env = await devicePiece(owner: victim);
      gateway.mailbox[me] = [env];
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(gateway.mailbox[me], [env]);
      expect(gateway.posts['/pieces/$me/ack'], isNull);
    });

    test('drops a device piece whose certificate the victim did not sign', () async {
      gateway.mailbox[me] = [await devicePiece(owner: coGuardian)];
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(Hive.box(MeshService.receivedSharesBoxName).isEmpty, isTrue);
      expect(gateway.mailbox[me], isEmpty);
    });
  });

  group("clips this user's own SOS device recorded", () {
    final plaintext = Uint8List.fromList(List<int>.generate(3000, (i) => (i * 7) % 256));
    final ownClip = _sha256Hex(plaintext);

    Uint8List pack(SecretBox box) => Uint8List.fromList([...box.nonce, ...box.mac.bytes, ...box.cipherText]);

    /// The device's message to this phone and the clip's ciphertext, sealed
    /// as device/justice_device/sealer.py does: the owner key is a share with
    /// x = 0 whose y is the whole clip key.
    Future<({Map<String, dynamic> env, Uint8List cipher})> ownDeviceClip({bool certifiedByMe = true, bool clipSigned = true}) async {
      final deviceEd = await Ed25519().newKeyPair();
      final deviceEdPub = base64Encode((await deviceEd.extractPublicKey()).bytes);
      final deviceX = await X25519().newKeyPair();
      final deviceXPub = base64Encode((await deviceX.extractPublicKey()).bytes);
      final deviceNode = _sha256Hex(base64Decode(deviceEdPub)).substring(0, 16);
      Future<String> deviceSign(String text) async =>
          base64Encode((await Ed25519().sign(utf8.encode(text), keyPair: deviceEd)).bytes);

      final key = SecretKey(List<int>.generate(32, (i) => i + 1));
      final cipher = pack(await AesGcm.with256bits().encrypt(plaintext, secretKey: key));
      final myX = (jsonDecode(await IdentityService.getQrPayload()) as Map)['x25519_public_key'] as String;
      final shared = await X25519().sharedSecretKey(
          keyPair: deviceX, remotePublicKey: SimplePublicKey(base64Decode(myX), type: KeyPairType.x25519));
      final wrap = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(secretKey: shared, info: utf8.encode('justice-chain-guardian-wrap-v1'));
      final sealed = base64Encode(pack(await AesGcm.with256bits().encrypt([0, ...await key.extractBytes()], secretKey: wrap)));
      final pieceHash = _sha256Hex(base64Decode(sealed));

      final cert = <String, Object>{
        'deviceNodeId': deviceNode,
        'deviceEd25519': deviceEdPub,
        'deviceX25519': deviceXPub,
        'deviceAnchoringAddress': '0xd9d08a9aeb67749a252fc0ec7afa925e1467366f',
        'ownerNodeId': me,
        'issuedAt': 1792900000,
      };
      cert['signature'] = certifiedByMe
          ? await IdentityService.signBytes(utf8.encode(DeviceLinkService.certificatePayload(cert)))
          : await victim.edSign(DeviceLinkService.certificatePayload(cert));
      return (
        cipher: cipher,
        env: <String, dynamic>{
          'id': 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0',
          'kind': 'device',
          'manifestHash': ownClip,
          'victimNodeId': me,
          'fromNodeId': deviceNode,
          'toNodeId': me,
          'sealedShare': sealed,
          'pieceHash': pieceHash,
          'senderX25519': deviceXPub,
          'signature': await deviceSign(DeviceLinkService.piecePayload(ownClip, me, deviceNode, me, pieceHash)),
          'certificate': cert,
          'share': {
            'cid': 'bafyownclip',
            'capturedAt': '2026-10-27T10:00:00+00:00',
            'quorum': 2,
            'signature': await deviceSign(clipSigned ? ownClip : 'something else'),
            'source': 'sos-device',
          },
          'blockNumber': 350,
        },
      );
    }

    tearDown(() => EvidenceVaultService.clientForTest = null);

    test('lists the clip in My evidence and plays it from IPFS with the key sealed for this phone', () async {
      final clip = await ownDeviceClip();
      gateway.mailbox[me] = [clip.env];
      expect(await CoGuardianService.fetchMailbox(), 1);
      expect(gateway.mailbox[me], isEmpty);

      final record = vault.get(ownClip) as Map;
      expect(record['source'], 'sos-device');
      expect(record['status'], 'anchored');
      expect(record['cid'], 'bafyownclip');
      expect(record['blockNumber'], 350);
      expect(Hive.box(MeshService.receivedSharesBoxName).isEmpty, isTrue); // not a guardian piece

      EvidenceVaultService.clientForTest = MockClient((r) async {
        expect(r.url.path, endsWith('bafyownclip'));
        return http.Response.bytes(clip.cipher, 200);
      });
      expect(await EvidenceVaultService.openOwnClip(ownClip), plaintext);
    });

    test("drops the clip when the device wasn't certified with this phone's key", () async {
      gateway.mailbox[me] = [(await ownDeviceClip(certifiedByMe: false)).env];
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(vault.get(ownClip), isNull);
      expect(gateway.mailbox[me], isEmpty);
    });

    test('drops the clip when the device did not sign it', () async {
      gateway.mailbox[me] = [(await ownDeviceClip(clipSigned: false)).env];
      expect(await CoGuardianService.fetchMailbox(), 0);
      expect(vault.get(ownClip), isNull);
    });

    test('refuses to play a download that is not the clip', () async {
      final clip = await ownDeviceClip();
      gateway.mailbox[me] = [clip.env];
      await CoGuardianService.fetchMailbox();
      final tampered = Uint8List.fromList(clip.cipher)..[40] ^= 1;
      EvidenceVaultService.clientForTest = MockClient((_) async => http.Response.bytes(tampered, 200));
      await expectLater(EvidenceVaultService.openOwnClip(ownClip), throwsA(anything));
    });
  });
}
