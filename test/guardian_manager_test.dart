import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/evidence_vault_service.dart';
import 'package:justice_chain/core/outbox_service.dart';
import 'package:justice_chain/logic/guardian_manager.dart';
import 'package:justice_chain/presentation/guardians_screen.dart';

void main() {
  late Directory tempDir;
  late Box vault;
  late Box outbox;

  Map<String, dynamic> contact(String name, {bool withKeys = true}) => {
        'name': name,
        'public_key': 'ed25519-$name',
        'x25519_public_key': withKeys ? 'x25519-$name' : null,
        'anchoring_address': '0x$name',
        'added_at': '2026-10-07T21:21:53.000',
      };

  Future<void> seed(Map<String, Map<String, dynamic>> contacts) =>
      vault.put('trusted_guardians', contacts);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guardian_test');
    Hive.init(tempDir.path);
    vault = await Hive.openBox('vault_box');
    outbox = await Hive.openBox(OutboxService.boxName);
    OutboxService.manageAdvertising = false;
  });

  tearDown(() async {
    OutboxService.manageAdvertising = true;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('GuardianManager', () {
    test('rename changes only the name and ignores blanks or unknown IDs', () async {
      await seed({'nodeA': contact('Alex')});

      await GuardianManager.renameGuardian('nodeA', '  Mum  ');
      await GuardianManager.renameGuardian('nodeA', '   ');
      await GuardianManager.renameGuardian('nobody', 'Ghost');

      final a = GuardianManager.getTrustedGuardians()['nodeA'] as Map;
      expect(a['name'], 'Mum');
      expect(a['public_key'], 'ed25519-Alex');
      expect(a['x25519_public_key'], 'x25519-Alex');
      expect(GuardianManager.getAllContacts().containsKey('nobody'), isFalse);
    });

    test('remove stops trusting the contact but keeps its keys for verification', () async {
      await seed({'nodeA': contact('Alex'), 'nodeB': contact('Bea')});

      await GuardianManager.removeGuardian('nodeA');

      expect(GuardianManager.isTrusted('nodeA'), isFalse);
      expect(GuardianManager.isTrusted('nodeB'), isTrue);
      expect(GuardianManager.getTrustedGuardians().keys, ['nodeB']);

      final kept = GuardianManager.getAllContacts()['nodeA'] as Map;
      expect(kept['public_key'], 'ed25519-Alex');
      expect(kept['anchoring_address'], '0xAlex');
      expect(kept['removed_at'], isNotNull);
    });

    test('remove cancels only outbound deliveries to that contact', () async {
      await seed({'nodeA': contact('Alex'), 'nodeB': contact('Bea')});
      await OutboxService.enqueueKeyShare('rec1', 'nodeA');
      await OutboxService.enqueueMeshRelay('rec1', 'nodeA');
      await OutboxService.enqueueShareForward('man1', 'nodeA');
      await OutboxService.enqueueKeyShare('rec1', 'nodeB');
      await OutboxService.enqueueRelayUpload('manFromA');
      await OutboxService.enqueueUpload('rec1');

      await GuardianManager.removeGuardian('nodeA');

      expect(outbox.keys.toSet(), {
        'key_share:rec1:nodeB',
        'relay_upload:manFromA',
        'ipfs_upload:rec1',
      });
    });

    test('cancelJobsForNode does not match a node ID that is a suffix of another', () async {
      await OutboxService.enqueueKeyShare('rec1', 'abc');
      await OutboxService.enqueueKeyShare('rec1', 'xabc');

      expect(await OutboxService.cancelJobsForNode('abc'), 1);
      expect(outbox.keys, ['key_share:rec1:xabc']);
    });

    test('removing an unknown contact does nothing', () async {
      await seed({'nodeA': contact('Alex')});
      await GuardianManager.removeGuardian('nobody');
      expect(GuardianManager.getTrustedGuardians().keys, ['nodeA']);
    });
  });

  group('single-guardian mode', () {
    test('is off by default and can be toggled', () async {
      expect(GuardianManager.allowSingleGuardian, isFalse);
      await GuardianManager.setAllowSingleGuardian(true);
      expect(GuardianManager.allowSingleGuardian, isTrue);
    });

    test('new recordings need 2 guardians unless the mode is on and fewer than 2 can hold keys', () async {
      expect(EvidenceVaultService.thresholdFor(0), 2);
      expect(EvidenceVaultService.thresholdFor(1), 2);

      await GuardianManager.setAllowSingleGuardian(true);
      expect(EvidenceVaultService.thresholdFor(0), 1);
      expect(EvidenceVaultService.thresholdFor(1), 1);
      expect(EvidenceVaultService.thresholdFor(2), 2);
      expect(EvidenceVaultService.thresholdFor(3), 2);
    });

    test('records saved before thresholds existed count as needing 2', () {
      expect(EvidenceVaultService.recordThreshold({'hash': 'old'}), 2);
      expect(EvidenceVaultService.recordThreshold({'threshold': 1}), 1);
    });
  });

  group('GuardiansScreen', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: GuardiansScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the quorum warning and the empty state', (tester) async {
      await pump(tester);
      expect(find.textContaining('Add at least 2 guardians'), findsOneWidget);
      expect(find.textContaining('No guardians yet'), findsOneWidget);
    });

    testWidgets('lists guardians and flags one that cannot hold keys', (tester) async {
      await tester.runAsync(() => seed({
            'aaaa1111bbbb2222': contact('Zara'),
            'cccc3333dddd4444': contact('Bob', withKeys: false),
          }));
      await pump(tester);

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Zara'), findsOneWidget);
      expect(find.textContaining('ID aaaa…2222'), findsOneWidget);
      expect(find.textContaining("Can't hold key pieces"), findsOneWidget);
      // Only one of the two can hold keys, so the warning still shows.
      expect(find.text('1 of 2 can hold key pieces'), findsOneWidget);
    });

    testWidgets('turning on single-guardian mode asks first; Cancel leaves it off', (tester) async {
      await tester.runAsync(() => seed({'nodeA': contact('Alex')}));
      await pump(tester);
      expect(find.textContaining('Add at least 2 guardians'), findsOneWidget);

      // The single-guardian switch; the police guardian switch comes after it.
      await tester.tap(find.byType(CupertinoSwitch).first);
      await tester.pumpAndSettle();
      expect(find.text('Let one guardian open recordings?'), findsOneWidget);
      expect(find.textContaining('stay that way'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(GuardianManager.allowSingleGuardian, isFalse);
      expect(find.textContaining('Add at least 2 guardians'), findsOneWidget);
    });

    testWidgets('with single-guardian mode on, the banner says so', (tester) async {
      await tester.runAsync(() async {
        await seed({'nodeA': contact('Alex')});
        await GuardianManager.setAllowSingleGuardian(true);
      });
      await pump(tester);

      expect(find.textContaining('Single-guardian mode is on'), findsOneWidget);
      expect(find.textContaining('Add at least'), findsNothing);
      expect(tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch).first).value, isTrue);
    });

    testWidgets('no warning with two guardians that can hold keys', (tester) async {
      await tester.runAsync(() => seed({
            'nodeA': contact('Alex'),
            'nodeB': contact('Bea'),
          }));
      await pump(tester);
      expect(find.textContaining('Add at least'), findsNothing);
    });
  });
}
