import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/fabric_ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/core/shamir.dart';
import 'package:justice_chain/logic/guardian_manager.dart';

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// A stand-in for the gateway that keeps the ledger's state and refuses what
/// the chaincode refuses, with the same messages the app relies on.
class _FakeGateway {
  final nodes = <String, Map<String, dynamic>>{};
  final guardians = <String, Map<String, dynamic>>{};
  final authorities = <String, Map<String, dynamic>>{};
  final shared = <String>{};
  final requests = <String, Map<String, dynamic>>{};
  bool failNextRelease = false;
  final posts = <String, List<Map<String, dynamic>>>{};

  /// How long a write takes to commit, like the real ledger (about 2 s).
  Duration commitDelay = Duration.zero;

  http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request r) async {
    final path = r.url.path;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (r.method == 'GET') {
      final id = parts.length == 2 ? parts[1] : '';
      switch (parts.first) {
        case 'nodes':
          return _json(nodes[id] == null ? {'found': false, 'nodeId': id} : {'found': true, ...nodes[id]!});
        case 'guardians':
          return _json(guardians[id] == null ? {'found': false, 'victimNodeId': id} : {'found': true, ...guardians[id]!});
        case 'authorities':
          return _json(authorities[id] == null ? {'found': false, 'mspId': id} : {'found': true, ...authorities[id]!});
        case 'access-requests':
          return _json(requests.values.where((r) => r['victimNodeId'] == id).toList());
        case 'access-request':
          return _json(requests[id] == null ? {'found': false, 'requestId': id} : {'found': true, ...requests[id]!});
      }
      return _json({'error': 'Not found'}, 404);
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    posts.putIfAbsent(path, () => []).add(body);
    await Future<void>.delayed(commitDelay);
    switch (path) {
      case '/nodes':
        nodes[body['nodeId'] as String] = {'nodeId': body['nodeId'], 'anchoringAddress': body['anchoringAddress']};
        return _json(nodes[body['nodeId']]!);
      case '/guardians':
        final victim = body['victimNodeId'] as String;
        final seq = body['sequence'] as int;
        final previous = guardians[victim]?['sequence'] as int? ?? 0;
        if (seq <= previous) return _json({'error': 'sequence must be greater than $previous'}, 400);
        for (final g in body['guardianNodeIds'] as List) {
          if (!nodes.containsKey(g)) return _json({'error': 'Guardian $g is not registered'}, 400);
        }
        guardians[victim] = {
          'victimNodeId': victim,
          'guardians': body['guardianNodeIds'],
          'sequence': seq,
          'signature': body['signature'],
        };
        return _json(guardians[victim]!);
      case '/releases':
        if (failNextRelease) {
          failNextRelease = false;
          return _json({'error': 'Fabric network unavailable'}, 503);
        }
        final request = requests[body['requestId']]!;
        final pieceHash = _sha256Hex(base64Decode(body['sealedShare'] as String));
        if (request['status'] == 'released') {
          final same = request['releasedBy'] == body['releaserNodeId'] && request['releasedShareHash'] == pieceHash;
          return same ? _json(request) : _json({'error': 'Access request is already released'}, 400);
        }
        final victim = request['victimNodeId'];
        final isGuardian = (guardians[victim]?['guardians'] as List?)?.contains(body['releaserNodeId']) ?? false;
        if (body['releaserNodeId'] != victim && !isGuardian) {
          return _json({'error': 'Only the victim or one of their registered guardians may release a piece'}, 400);
        }
        if (body['shareX'] == request['heldShareX']) {
          return _json({'error': 'SimPoliceMSP already holds piece ${body['shareX']}'}, 400);
        }
        request.addAll({'status': 'released', 'releasedBy': body['releaserNodeId'], 'releasedShareHash': pieceHash});
        return _json(request);
      case '/authority-shares':
        final key = '${body['manifestHash']}|${body['authorityMsp']}';
        if (shared.contains(key)) return _json({'error': 'This clip is already shared with ${body['authorityMsp']}'}, 400);
        shared.add(key);
        return _json({'manifestHash': body['manifestHash'], 'blockNumber': 42});
    }
    return _json({'error': 'Not found'}, 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box vault;
  late _FakeGateway gateway;
  late String myNodeId;
  late String myX25519;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('authority_test');
    Hive.init(tempDir.path);
    vault = await Hive.openBox('vault_box');
    await Hive.openBox(OutboxService.boxName);
    await Hive.openBox(MeshService.receivedSharesBoxName);
    OutboxService.manageAdvertising = false;
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    await IdentityService.initializeDevice();
    final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
    myNodeId = qr['node_id'] as String;
    myX25519 = qr['x25519_public_key'] as String;
    gateway = _FakeGateway();
    AuthorityService.gatewayForTest =
        FabricLedgerService(gatewayUrl: 'http://gw', client: MockClient(gateway.handle));
    AuthorityService.demoBuildForTest = true;
  });

  tearDown(() async {
    AuthorityService.gatewayForTest = null;
    AuthorityService.demoBuildForTest = null;
    OutboxService.dispatchOverride = null;
    OutboxService.manageAdvertising = true;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> addGuardianContact(String nodeId) => vault.put('trusted_guardians', {
        ...Map<String, dynamic>.from(vault.get('trusted_guardians', defaultValue: {}) as Map),
        nodeId: {'name': nodeId, 'public_key': 'ed', 'x25519_public_key': null, 'added_at': '2026-10-14T10:00:00'},
      });

  group('registerThisPhone', () {
    test('sends the phone keys signed by both keys, once', () async {
      await AuthorityService.registerThisPhone();
      await AuthorityService.registerThisPhone();

      final sent = gateway.posts['/nodes']!;
      expect(sent, hasLength(1));
      final body = sent.single;
      final qr = jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;
      final payload = 'justice-chain/register-node/v1|$myNodeId|${qr['public_key']}|'
          '${qr['x25519_public_key']}|${(qr['anchoring_address'] as String).toLowerCase()}';
      expect(body['nodeId'], myNodeId);
      expect(body['anchoringAddress'], (qr['anchoring_address'] as String).toLowerCase());
      expect(body['anchoringSignature'], await AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload))));
      final edOk = await Ed25519().verify(
        utf8.encode(payload),
        signature: Signature(
          base64Decode(body['ed25519Signature'] as String),
          publicKey: SimplePublicKey(base64Decode(qr['public_key'] as String), type: KeyPairType.ed25519),
        ),
      );
      expect(edOk, isTrue);
    });

    test('callers at the same moment send one registration, not two', () async {
      // Two at once collided on the live ledger (read conflict, HTTP 502).
      await Future.wait([
        AuthorityService.registerThisPhone(),
        AuthorityService.registerThisPhone(),
        AuthorityService.syncGuardians(),
      ]);
      expect(gateway.posts['/nodes'], hasLength(1));
    });
  });

  test('guardian syncs at the same moment run one after another; the second sends nothing', () async {
    const a = 'aaaaaaaaaaaaaaaa';
    await addGuardianContact(a);
    gateway.nodes[a] = {'nodeId': a};
    gateway.commitDelay = const Duration(milliseconds: 50);
    await Future.wait([AuthorityService.syncGuardians(), AuthorityService.syncGuardians()]);
    expect(gateway.posts['/guardians'], hasLength(1));
  });

  group('syncGuardians', () {
    test('names only registered guardians, then adds the rest once they register', () async {
      const a = 'aaaaaaaaaaaaaaaa', b = '1111111111111111';
      await addGuardianContact(a);
      await addGuardianContact(b);
      gateway.nodes[a] = {'nodeId': a};

      await expectLater(AuthorityService.syncGuardians(), throwsA(isA<StateError>()));
      var sent = gateway.posts['/guardians']!.last;
      expect(sent['guardianNodeIds'], [a]);
      expect(sent['sequence'], 1);
      expect(sent['signature'],
          await AnchoringService.signAnchor(_sha256Hex(utf8.encode('justice-chain/set-guardians/v1|$myNodeId|1|$a'))));

      gateway.nodes[b] = {'nodeId': b};
      await AuthorityService.syncGuardians();
      sent = gateway.posts['/guardians']!.last;
      expect(sent['guardianNodeIds'], [b, a], reason: 'sorted, as the chaincode signs them');
      expect(sent['sequence'], 2);

      await AuthorityService.syncGuardians();
      expect(gateway.posts['/guardians'], hasLength(2), reason: 'already in sync: nothing sent');
    });

    test('continues from the ledger\'s sequence (e.g. after a reinstall)', () async {
      const a = 'aaaaaaaaaaaaaaaa';
      await addGuardianContact(a);
      gateway.nodes[a] = {'nodeId': a};
      gateway.guardians[myNodeId] = {'victimNodeId': myNodeId, 'guardians': <String>[], 'sequence': 5};

      await AuthorityService.syncGuardians();
      expect(gateway.posts['/guardians']!.single['sequence'], 6);
    });

    test('a list from before the ledger kept signatures is signed again, once', () async {
      const a = 'aaaaaaaaaaaaaaaa';
      await addGuardianContact(a);
      gateway.nodes[a] = {'nodeId': a};
      gateway.guardians[myNodeId] = {'victimNodeId': myNodeId, 'guardians': [a], 'sequence': 2};

      await AuthorityService.syncGuardians();
      await AuthorityService.syncGuardians();
      final sent = gateway.posts['/guardians']!.single;
      expect(sent['sequence'], 3);
      expect(sent['guardianNodeIds'], [a]);
    });

    test('removing every guardian clears the list on the ledger', () async {
      const a = 'aaaaaaaaaaaaaaaa';
      await addGuardianContact(a);
      gateway.nodes[a] = {'nodeId': a};
      await AuthorityService.syncGuardians();

      await GuardianManager.removeGuardian(a);
      await AuthorityService.syncGuardians();
      expect(gateway.posts['/guardians']!.last['guardianNodeIds'], isEmpty);
    });
  });

  group('shareRecordWithAuthority', () {
    late SimpleKeyPair deskKey;
    late SimpleKeyPair guardianKey;

    Future<String> recordWith({required int threshold, String status = 'anchored'}) async {
      final dir = await Directory.systemTemp.createTemp('clip');
      final clip = File('${dir.path}/clip.mp4')..writeAsBytesSync(utf8.encode('clip ${DateTime.now()}'));
      guardianKey = await X25519().newKeyPair();
      final guardianPub = base64Encode((await guardianKey.extractPublicKey()).bytes);
      final sealed = await EvidenceEncryptor.encryptAndSeal(
        clip.path,
        guardians: [(nodeId: 'gggggggggggggggg', x25519PublicKeyB64: guardianPub)],
        threshold: threshold,
      );
      await vault.put(sealed.plaintextHash, {
        'authorityMsp': AuthorityService.simPoliceMsp,
        'path': sealed.cipherPath,
        'hash': sealed.plaintextHash,
        'wrappedKey': sealed.wrappedKeyB64,
        'guardianShares': sealed.guardianShares,
        'nextShareX': sealed.nextShareX,
        'threshold': sealed.threshold,
        'status': status,
      });
      return sealed.plaintextHash;
    }

    setUp(() async {
      deskKey = await X25519().newKeyPair();
      gateway.authorities[AuthorityService.simPoliceMsp] = {
        'mspId': AuthorityService.simPoliceMsp,
        'name': 'Demo Police Authority (SIMULATED)',
        'publicKey': base64Encode((await deskKey.extractPublicKey()).bytes),
        'revoked': false,
      };
    });

    test('shares a new piece that, with one guardian\'s piece, opens the clip', () async {
      final key = await recordWith(threshold: 2);
      final x = (vault.get(key) as Map)['nextShareX'] as int;

      await AuthorityService.shareRecordWithAuthority(key);

      final body = gateway.posts['/authority-shares']!.single;
      expect(body['shareX'], x);
      expect(body['threshold'], 2);
      final consent = 'justice-chain/share-with-authority/v1|$key|SimPoliceMSP|$x|2|'
          '${_sha256Hex(base64Decode(body['sealedShare'] as String))}';
      expect(body['signature'], await AnchoringService.signAnchor(_sha256Hex(utf8.encode(consent))));

      final record = vault.get(key) as Map;
      expect(record['nextShareX'], x + 1, reason: 'the index is not reused by a later guardian');
      expect((record['authorityShare'] as Map)['blockNumber'], 42);

      final policePiece = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: body['sealedShare'] as String,
        ownX25519KeyPair: deskKey,
        senderX25519PublicKeyB64: myX25519,
      );
      final guardianPiece = await EvidenceEncryptor.unsealGuardianShare(
        sealedShareB64: (record['guardianShares'] as Map)['gggggggggggggggg'] as String,
        ownX25519KeyPair: guardianKey,
        senderX25519PublicKeyB64: myX25519,
      );
      expect(policePiece.x, x);
      final plaintext = await EvidenceEncryptor.decryptFileWithShares(
        cipherPath: record['path'] as String,
        shares: [policePiece, guardianPiece],
        threshold: 2,
      );
      expect(_sha256Hex(plaintext), key);
    });

    test('never shares a single-guardian recording', () async {
      final key = await recordWith(threshold: 1);
      await AuthorityService.shareRecordWithAuthority(key);
      expect(gateway.posts['/authority-shares'], isNull);
      expect(((vault.get(key) as Map)['authorityShare'] as Map)['skipped'], 'single-guardian recording');
    });

    test('waits until the recording is anchored', () async {
      final key = await recordWith(threshold: 2, status: 'uploaded_to_ipfs');
      await expectLater(AuthorityService.shareRecordWithAuthority(key), throwsA(isA<JobNotReady>()));
      expect(gateway.posts['/authority-shares'], isNull);
    });

    test('a retry after a lost reply counts as shared, with the same piece index', () async {
      final key = await recordWith(threshold: 2);
      gateway.shared.add('$key|SimPoliceMSP');
      await AuthorityService.shareRecordWithAuthority(key);
      final record = vault.get(key) as Map;
      expect(record['authorityShare'], isNotNull);
      expect(record['authorityShareX'], gateway.posts['/authority-shares']!.single['shareX']);
    });

    test('refuses a revoked authority', () async {
      final key = await recordWith(threshold: 2);
      gateway.authorities[AuthorityService.simPoliceMsp]!['revoked'] = true;
      await expectLater(AuthorityService.shareRecordWithAuthority(key), throwsA(isA<StateError>()));
      expect(gateway.posts['/authority-shares'], isNull);
    });

    group('access requests', () {
      const victim = 'vvvvvvvvvvvvvvvv';

      /// Shares [key] with the police and files a request for it, as the portal would.
      Future<String> requestFor(String key, {String? victimNodeId, String status = 'open'}) async {
        await AuthorityService.shareRecordWithAuthority(key);
        final id = 'req-${gateway.requests.length + 1}';
        gateway.requests[id] = {
          'requestId': id,
          'manifestHash': key,
          'authorityMsp': AuthorityService.simPoliceMsp,
          'victimNodeId': victimNodeId ?? myNodeId,
          'heldShareX': (vault.get(key) as Map)['authorityShareX'],
          'threshold': 2,
          'requestedBy': 'Officer',
          'reason': 'Assault complaint',
          'caseRef': 'FIR 12/2026',
          'status': status,
          'requestedAt': 1760000000,
        };
        return id;
      }

      /// What the police desk can open: its held piece plus the released one.
      Future<void> expectPoliceCanOpen(String key) async {
        final held = gateway.posts['/authority-shares']!.last['sealedShare'] as String;
        final released = gateway.posts['/releases']!.last['sealedShare'] as String;
        final pieces = [
          for (final s in [held, released])
            await EvidenceEncryptor.unsealGuardianShare(
              sealedShareB64: s,
              ownX25519KeyPair: deskKey,
              senderX25519PublicKeyB64: myX25519,
            ),
        ];
        final plaintext = await EvidenceEncryptor.decryptFileWithShares(
          cipherPath: (vault.get(key) as Map)['path'] as String,
          shares: pieces,
          threshold: 2,
        );
        expect(_sha256Hex(plaintext), key);
      }

      /// Gives this phone a guardian piece of [key], as the victim's phone would over the mesh.
      Future<ShamirShare> holdGuardianPiece(String key, String victimNodeId, {String? forwardedBy}) async {
        final piece = await EvidenceEncryptor.unsealGuardianShare(
          sealedShareB64: ((vault.get(key) as Map)['guardianShares'] as Map)['gggggggggggggggg'] as String,
          ownX25519KeyPair: guardianKey,
          senderX25519PublicKeyB64: myX25519,
        );
        await Hive.box(MeshService.receivedSharesBoxName).put('$key:${forwardedBy ?? victimNodeId}', {
          'manifestHash': key,
          'victimNodeId': victimNodeId,
          'senderX25519': myX25519,
          'sealedShare': await EvidenceEncryptor.sealShare(piece, myX25519),
          'forwardedBy': forwardedBy,
        });
        return piece;
      }

      test('the victim approves with a new piece that, with the held one, opens the clip', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key);
        final x = (vault.get(key) as Map)['nextShareX'] as int;

        await AuthorityService.releaseForRequest(id);

        final body = gateway.posts['/releases']!.single;
        expect(body['releaserNodeId'], myNodeId);
        expect(body['shareX'], x);
        final payload = 'justice-chain/release-share/v1|$id|$key|SimPoliceMSP|$x|'
            '${_sha256Hex(base64Decode(body['sealedShare'] as String))}';
        expect(body['signature'], await AnchoringService.signAnchor(_sha256Hex(utf8.encode(payload))));
        expect((vault.get(key) as Map)['nextShareX'], x + 1);
        final kept = (vault.get('authority_releases') as Map)[id] as Map;
        expect(kept['releasedAt'], isNotNull);
        expect(kept.containsKey('sealedShare'), isFalse, reason: 'not kept after success');
        await expectPoliceCanOpen(key);
      });

      test('a retry after a failure sends the very same piece', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key);
        gateway.failNextRelease = true;

        await expectLater(AuthorityService.releaseForRequest(id), throwsStateError);
        await AuthorityService.releaseForRequest(id);

        final sent = gateway.posts['/releases']!;
        expect(sent, hasLength(2));
        expect(sent[1]['sealedShare'], sent[0]['sealedShare']);
        expect(sent[1]['shareX'], sent[0]['shareX']);
        expect(gateway.requests[id]!['status'], 'released');
        await expectPoliceCanOpen(key);
      });

      test('a guardian re-seals the piece the victim gave them', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key, victimNodeId: victim);
        gateway.guardians[victim] = {'victimNodeId': victim, 'guardians': [myNodeId], 'sequence': 1};
        final piece = await holdGuardianPiece(key, victim);

        await AuthorityService.releaseForRequest(id);

        final body = gateway.posts['/releases']!.single;
        expect(body['releaserNodeId'], myNodeId);
        expect(body['shareX'], piece.x);
        await expectPoliceCanOpen(key);
      });

      test('a guardian sees only open requests for clips it holds its own piece of', () async {
        // Each recording has its own guardian key, so hold its piece right away.
        final mine = await recordWith(threshold: 2);
        await holdGuardianPiece(mine, victim);
        final open = await requestFor(mine, victimNodeId: victim);
        final forwarded = await recordWith(threshold: 2);
        await holdGuardianPiece(forwarded, victim, forwardedBy: 'cccccccccccccccc');
        await requestFor(forwarded, victimNodeId: victim);
        final released = await recordWith(threshold: 2);
        await holdGuardianPiece(released, victim);
        await requestFor(released, victimNodeId: victim, status: 'released');
        final ownOpen = await requestFor(await recordWith(threshold: 2));

        expect([for (final r in await AuthorityService.openRequestsIGuard()) r['requestId']], [open]);
        expect([for (final r in await AuthorityService.openRequestsForMyRecordings()) r['requestId']], [ownOpen]);
      });

      test('an already-released request sends nothing', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key, status: 'released');
        await AuthorityService.releaseForRequest(id);
        expect(gateway.posts['/releases'], isNull);
      });

      test('refuses a revoked authority and a recording not on this phone', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key);
        gateway.authorities[AuthorityService.simPoliceMsp]!['revoked'] = true;
        await expectLater(AuthorityService.releaseForRequest(id), throwsStateError);

        gateway.authorities[AuthorityService.simPoliceMsp]!['revoked'] = false;
        await vault.delete(key);
        await expectLater(AuthorityService.releaseForRequest(id), throwsStateError);
        expect(gateway.posts['/releases'], isNull);
      });

      test('approving queues the release in the outbox, which sends it', () async {
        final key = await recordWith(threshold: 2);
        final id = await requestFor(key);
        await AuthorityService.approveRequest(id);
        // approveRequest starts the outbox without waiting; let that run finish.
        final outbox = Hive.box(OutboxService.boxName);
        for (var i = 0; i < 200 && outbox.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(Hive.box(OutboxService.boxName).isEmpty, isTrue);
        expect(gateway.requests[id]!['status'], 'released');
      });
    });
  });

  group('opt-in', () {
    test('only demo builds can opt in, and only new recordings use it', () async {
      AuthorityService.demoBuildForTest = false;
      await expectLater(AuthorityService.setShareWithAuthority(true), throwsStateError);
      expect(AuthorityService.authorityForNewRecordings(), isNull);

      AuthorityService.demoBuildForTest = true;
      expect(AuthorityService.authorityForNewRecordings(), isNull, reason: 'not opted in yet');
      await AuthorityService.setShareWithAuthority(true);
      expect(AuthorityService.authorityForNewRecordings(), AuthorityService.simPoliceMsp);
      await AuthorityService.setShareWithAuthority(false);
      expect(AuthorityService.authorityForNewRecordings(), isNull);
    });

    test('without the Fabric gateway there is nothing to opt in to', () async {
      AuthorityService.gatewayForTest = null;
      await AuthorityService.setShareWithAuthority(true);
      expect(AuthorityService.ledgerFeaturesEnabled, isFalse);
      expect(AuthorityService.authorityForNewRecordings(), isNull);
    });
  });

  test('the outbox runs registry jobs that have no recording', () async {
    await AuthorityService.requestRegistration();
    await AuthorityService.requestGuardianSync();
    await OutboxService.process();
    expect(Hive.box(OutboxService.boxName).isEmpty, isTrue);
    expect(gateway.posts['/nodes'], hasLength(1));
  });
}
