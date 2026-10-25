import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/anchoring_service.dart';
import 'package:justice_chain/core/authority_service.dart';
import 'package:justice_chain/core/evidence_encryptor.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/core/ledger/ledger_service.dart';
import 'package:justice_chain/core/mesh_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/core/recovery_code.dart';
import 'package:justice_chain/core/recovery_service.dart';
import 'package:justice_chain/logic/guardian_manager.dart';
import 'package:justice_chain/presentation/recovery_code_screen.dart';

/// A ledger holding anchors by hash, listed per node, like /history and /verify.
class _FakeLedger implements LedgerService {
  final anchors = <String, AnchorVerificationResult>{};

  @override
  String get name => 'fake';

  @override
  Future<String> recordAnchor({
    required String manifestHashHex,
    required String cid,
    required DateTime capturedAt,
    required String nodeId,
    required String signatureHex,
  }) async {
    anchors[manifestHashHex] = AnchorVerificationResult(
      found: true,
      cid: cid,
      capturedAt: capturedAt,
      anchoredAt: DateTime.now(),
      nodeId: nodeId,
      signer: 'signer',
    );
    return 'tx';
  }

  @override
  Future<AnchorVerificationResult> verifyEvidence(String hash) async =>
      anchors[hash] ??
      AnchorVerificationResult(
        found: false,
        cid: '',
        capturedAt: DateTime(1970),
        anchoredAt: DateTime(1970),
        nodeId: '',
        signer: '',
      );

  @override
  Future<AnchorBlock?> findAnchorBlock(String hash) async => null;

  @override
  Future<List<String>> getEvidenceHistory(String nodeId) async =>
      [for (final e in anchors.entries) if (e.value.nodeId == nodeId) e.key];
}

Future<Map<String, dynamic>> _qr() async => jsonDecode(await IdentityService.getQrPayload()) as Map<String, dynamic>;

/// A brand-new phone: empty secure storage, keys made on first start.
Future<void> _newPhone() async {
  FlutterSecureStorage.setMockInitialValues({});
  IdentityService.resetCacheForTest();
  await IdentityService.initializeDevice();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecoveryCode', () {
    test('formats as six groups of five and reads back', () {
      final secret = RecoveryCode.newSecret();
      final code = RecoveryCode.format(secret);
      expect(code, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{5}-){5}[0-9A-HJKMNP-TV-Z]{5}$')));
      expect(RecoveryCode.parse(code), secret);
      expect(RecoveryCode.parse(code.toLowerCase().replaceAll('-', ' ')), secret, reason: 'case and spacing');
    });

    test('reads O as 0 and I/L as 1', () {
      final secret = List<int>.filled(16, 0);
      final code = RecoveryCode.format(secret);
      expect(code.startsWith('00000'), isTrue);
      expect(RecoveryCode.parse('OOOOO${code.substring(5)}'), secret);
    });

    test('refuses a typo or a wrong length', () {
      final code = RecoveryCode.format(RecoveryCode.newSecret());
      var typos = 0;
      for (var i = 0; i < code.length; i++) {
        if (code[i] == '-') continue;
        final swapped = code[i] == 'A' ? 'B' : 'A';
        try {
          RecoveryCode.parse(code.replaceRange(i, i + 1, swapped));
        } on FormatException {
          typos++;
        }
      }
      expect(typos, 30, reason: 'every single-character typo is caught');
      expect(() => RecoveryCode.parse(code.substring(0, 20)), throwsFormatException);
      expect(() => RecoveryCode.parse('${code.substring(0, 34)}U'), throwsFormatException);
    });

    test('derives the same keys every time, and different keys per label', () async {
      final secret = RecoveryCode.newSecret();
      final a = await RecoveryCode.deriveKeys(secret);
      final b = await RecoveryCode.deriveKeys(List.of(secret));
      expect(a.ed25519Seed, b.ed25519Seed);
      expect(a.anchoringKey, b.anchoringKey);
      expect({base64Encode(a.ed25519Seed), base64Encode(a.x25519Seed), base64Encode(a.evidenceRoot)}, hasLength(3));
      final other = await RecoveryCode.deriveKeys(RecoveryCode.newSecret());
      expect(other.ed25519Seed, isNot(a.ed25519Seed));
    });
  });

  group('identity from a recovery code', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('a new phone shows its code until it is confirmed', () async {
      await _newPhone();
      final code = await IdentityService.pendingRecoveryCode();
      expect(code, isNotNull);
      expect(await IdentityService.hasRecoveryCode(), isTrue);
      await IdentityService.confirmRecoveryCodeSaved();
      expect(await IdentityService.pendingRecoveryCode(), isNull);
      expect(await IdentityService.hasRecoveryCode(), isTrue, reason: 'clips stay recoverable');
    });

    test('restoring on another phone gives back the same identity', () async {
      await _newPhone();
      final code = (await IdentityService.pendingRecoveryCode())!;
      final original = await _qr();
      final signature = await IdentityService.signBytes(utf8.encode('hello'));

      await _newPhone();
      expect((await _qr())['node_id'], isNot(original['node_id']));
      await IdentityService.restoreFromRecoveryCode(code: code, name: 'Asha', pin: '2580');

      expect(await _qr(), original, reason: 'node ID, Ed25519, X25519 and anchoring address');
      expect(await IdentityService.signBytes(utf8.encode('hello')), signature);
      expect(await IdentityService.isRegistered(), isTrue);
      expect(await IdentityService.verifyPin('2580'), isTrue);
      expect(await IdentityService.pendingRecoveryCode(), isNull);
    });

    test('a mistyped code changes nothing', () async {
      await _newPhone();
      final before = await _qr();
      final code = RecoveryCode.format(RecoveryCode.newSecret());
      final typo = code.replaceRange(0, 1, code[0] == 'A' ? 'B' : 'A');
      await expectLater(
        IdentityService.restoreFromRecoveryCode(code: typo, name: 'Asha', pin: '2580'),
        throwsFormatException,
      );
      expect(await _qr(), before);
    });

    test('a phone from before recovery codes keeps random clip keys', () async {
      FlutterSecureStorage.setMockInitialValues({'private_key': base64Encode(List.filled(32, 7))});
      IdentityService.resetCacheForTest();
      await IdentityService.initializeDevice();
      expect(await IdentityService.pendingRecoveryCode(), isNull);
      expect(await IdentityService.hasRecoveryCode(), isFalse);
      expect(await IdentityService.clipKeyFor('ab' * 32), isNull);
    });
  });

  group('RecoveryService', () {
    late Directory tempDir;
    late _FakeLedger ledger;
    final ipfs = <String, List<int>>{};

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('recovery_test');
      Hive.init(tempDir.path);
      await Hive.openBox('vault_box');
      await Hive.openBox(OutboxService.boxName);
      await Hive.openBox(MeshService.receivedSharesBoxName);
      await Hive.openBox(MeshService.relayBoxName);
      OutboxService.manageAdvertising = false;
      ledger = _FakeLedger();
      AnchoringService.ledgerForTest = ledger;
      ipfs.clear();
      RecoveryService.clientForTest = MockClient((r) async {
        final bytes = ipfs[r.url.pathSegments.last];
        return bytes == null ? http.Response('not found', 404) : http.Response.bytes(bytes, 200);
      });
    });

    tearDown(() async {
      AnchoringService.ledgerForTest = null;
      RecoveryService.clientForTest = null;
      OutboxService.manageAdvertising = true;
      await Hive.deleteFromDisk();
      await Hive.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// Records a clip on the current phone: sealed, "uploaded" and anchored.
    Future<(String, List<int>)> record(String label, {String? anchoredBy}) async {
      final dir = await Directory.systemTemp.createTemp('clip');
      final bytes = utf8.encode('clip $label ${DateTime.now().microsecondsSinceEpoch}');
      final clip = File('${dir.path}/clip.mp4')..writeAsBytesSync(bytes);
      final sealed = await EvidenceEncryptor.encryptAndSeal(clip.path);
      final cid = 'bafy$label';
      ipfs[cid] = await File(sealed.cipherPath).readAsBytes();
      await ledger.recordAnchor(
        manifestHashHex: sealed.plaintextHash,
        cid: cid,
        capturedAt: DateTime(2026, 10, 14, 9),
        nodeId: anchoredBy ?? await IdentityService.getMyNodeId(),
        signatureHex: 'sig',
      );
      return (sealed.plaintextHash, bytes);
    }

    test('a new phone with only the code lists and opens the old clips', () async {
      await _newPhone();
      final code = (await IdentityService.pendingRecoveryCode())!;
      final (first, firstBytes) = await record('one');
      final (second, secondBytes) = await record('two');
      await _newPhone(); // someone else's clip, not to be listed
      await record('other');

      await _newPhone(); // the replacement phone, with nothing on it
      expect(await RecoveryService.restore(code: code, name: 'Asha', pin: '2580'), 2);

      final vault = Hive.box('vault_box');
      expect((vault.get(first) as Map)['status'], RecoveryService.restoredStatus);
      expect((vault.get(first) as Map)['cid'], 'bafyone');
      expect(await RecoveryService.openRestoredClip(first), firstBytes);
      expect(await RecoveryService.openRestoredClip(second), secondBytes);
      expect(await RecoveryService.restoreEvidenceList(), 0, reason: 'already listed');
    });

    test('a changed file on IPFS is refused', () async {
      await _newPhone();
      final code = (await IdentityService.pendingRecoveryCode())!;
      final (hash, _) = await record('one');
      ipfs['bafyone']![40] ^= 1;
      await _newPhone();
      await RecoveryService.restore(code: code, name: 'Asha', pin: '2580');
      await expectLater(RecoveryService.openRestoredClip(hash), throwsA(anything));
    });

    test('the wrong code opens nothing', () async {
      await _newPhone();
      final (hash, _) = await record('one');
      await _newPhone();
      final wrongCode = (await IdentityService.pendingRecoveryCode())!;
      await Hive.box('vault_box').put(hash, {'hash': hash, 'cid': 'bafyone', 'status': 'restored'});
      await IdentityService.restoreFromRecoveryCode(code: wrongCode, name: 'X', pin: '1111');
      await expectLater(RecoveryService.openRestoredClip(hash), throwsA(anything));
    });

    test('an unreachable ledger is reported, not treated as no clips', () async {
      await _newPhone();
      final code = (await IdentityService.pendingRecoveryCode())!;
      AnchoringService.ledgerForTest = _BrokenLedger();
      await expectLater(RecoveryService.restore(code: code, name: 'Asha', pin: '2580'), throwsStateError);
    });

    test('guardian sync waits until a guardian is paired again', () async {
      await _newPhone();
      final code = (await IdentityService.pendingRecoveryCode())!;
      await _newPhone();
      await RecoveryService.restore(code: code, name: 'Asha', pin: '2580');
      expect(Hive.box('vault_box').get('guardian_sync_paused'), isTrue);
      await GuardianManager.addGuardian(nodeId: 'gggggggggggggggg', publicKey: 'ed', name: 'G');
      expect(Hive.box('vault_box').get('guardian_sync_paused'), isNull);
      expect(AuthorityService.ledgerFeaturesEnabled, isFalse, reason: 'no gateway in this test');
    });

    test('clip keys are the content hash under the evidence root, so they differ per clip', () async {
      await _newPhone();
      final a = await (await IdentityService.clipKeyFor('aa' * 32))!.extractBytes();
      final b = await (await IdentityService.clipKeyFor('bb' * 32))!.extractBytes();
      expect(a, isNot(b));
      expect(crypto.sha256.convert(a).toString(), isNot(crypto.sha256.convert(b).toString()));
    });
  });

  group('RecoveryCodeScreen', () {
    testWidgets('shows the code once and needs its last group', (tester) async {
      await tester.runAsync(_newPhone);
      final code = (await tester.runAsync(IdentityService.pendingRecoveryCode))!;
      var done = false;
      await tester.pumpWidget(MaterialApp(home: RecoveryCodeScreen(onDone: () => done = true)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      for (final group in code.split('-')) {
        expect(find.text(group), findsOneWidget);
      }

      await tester.enterText(find.byKey(const ValueKey('recovery-confirm')), 'WRONG');
      await tester.ensureVisible(find.text("I've written it down"));
      await tester.tap(find.text("I've written it down"));
      await tester.pump();
      expect(done, isFalse);
      expect(find.textContaining('not the last group'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('recovery-confirm')), code.split('-').last.toLowerCase());
      await tester.ensureVisible(find.text("I've written it down"));
      await tester.tap(find.text("I've written it down"));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(done, isTrue);
      expect(await tester.runAsync(IdentityService.pendingRecoveryCode), isNull);
    });
  });
}

class _BrokenLedger extends _FakeLedger {
  @override
  Future<List<String>> getEvidenceHistory(String nodeId) => Future.error(StateError('offline'));
}
