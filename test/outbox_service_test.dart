import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:justice_chain/core/outbox_service.dart';

void main() {
  late Directory tempDir;
  late Box box;
  late List<(String, Map<String, dynamic>)> dispatched;

  Map<String, dynamic> job(String id) =>
      Map<String, dynamic>.from(box.get(id) as Map);

  /// Makes a backed-off job due again without waiting for real time.
  Future<void> makeDue(String id) async {
    final j = job(id)
      ..['nextAttemptAt'] =
          DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String();
    await box.put(id, j);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('outbox_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox(OutboxService.boxName);
    dispatched = [];
    OutboxService.manageAdvertising = false;
    OutboxService.dispatchOverride = (type, payload) async {
      dispatched.add((type, payload));
    };
  });

  tearDown(() async {
    OutboxService.dispatchOverride = null;
    OutboxService.manageAdvertising = true;
    await Hive.deleteBoxFromDisk(OutboxService.boxName);
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('enqueue', () {
    test('stores a fresh job that is due immediately', () async {
      await OutboxService.enqueueUpload('rec1');

      final j = job('ipfs_upload:rec1');
      expect(j['type'], OutboxService.jobUpload);
      expect(j['payload'], {'recordKey': 'rec1'});
      expect(j['attempts'], 0);
      expect(j['failed'], false);
      expect(j['lastError'], isNull);
      expect(
        DateTime.parse(j['nextAttemptAt'] as String).isAfter(DateTime.now()),
        isFalse,
      );
    });

    test('enqueueing the same id twice keeps the original job', () async {
      await OutboxService.enqueueAnchor('rec1');
      final original = job('anchor:rec1')..['attempts'] = 3;
      await box.put('anchor:rec1', original);

      await OutboxService.enqueueAnchor('rec1');

      expect(box.length, 1);
      expect(job('anchor:rec1')['attempts'], 3);
    });

    test('helpers build per-guardian ids and payloads', () async {
      await OutboxService.enqueueKeyShare('rec1', 'nodeA');
      await OutboxService.enqueueKeyShare('rec1', 'nodeB');
      await OutboxService.enqueueMeshRelay('rec1', 'nodeA');
      await OutboxService.enqueueRelayUpload('manifest1');
      await OutboxService.enqueueShareForward('manifest1', 'nodeC');

      expect(box.keys.toSet(), {
        'key_share:rec1:nodeA',
        'key_share:rec1:nodeB',
        'mesh_relay:rec1:nodeA',
        'relay_upload:manifest1',
        'share_forward:manifest1:nodeC',
      });
      expect(job('key_share:rec1:nodeB')['payload'],
          {'recordKey': 'rec1', 'guardianNodeId': 'nodeB'});
      expect(job('share_forward:manifest1:nodeC')['payload'],
          {'recordKey': 'manifest1', 'toNodeId': 'nodeC'});
    });
  });

  group('process', () {
    test('runs due jobs and removes them on success', () async {
      await OutboxService.enqueueUpload('rec1');
      await OutboxService.enqueueAnchor('rec1');

      await OutboxService.process();

      expect(box.isEmpty, isTrue);
      expect(dispatched.map((d) => d.$1).toSet(),
          {OutboxService.jobUpload, OutboxService.jobAnchor});
      expect(dispatched.first.$2['recordKey'], 'rec1');
    });

    test('a failure keeps the job and schedules a 30 s retry', () async {
      OutboxService.dispatchOverride =
          (_, __) async => throw Exception('network down');
      await OutboxService.enqueueUpload('rec1');

      final before = DateTime.now();
      await OutboxService.process();

      final j = job('ipfs_upload:rec1');
      expect(j['attempts'], 1);
      expect(j['failed'], false);
      expect(j['lastError'], contains('network down'));
      final next = DateTime.parse(j['nextAttemptAt'] as String);
      expect(next.difference(before).inSeconds, inInclusiveRange(29, 31));
    });

    test('a job that is not yet due is skipped', () async {
      await OutboxService.enqueueUpload('rec1');
      final j = job('ipfs_upload:rec1')
        ..['nextAttemptAt'] =
            DateTime.now().add(const Duration(minutes: 5)).toIso8601String();
      await box.put('ipfs_upload:rec1', j);

      await OutboxService.process();

      expect(dispatched, isEmpty);
      expect(box.containsKey('ipfs_upload:rec1'), isTrue);
    });

    test('backoff doubles on each failure and is capped at one hour', () async {
      OutboxService.dispatchOverride = (_, __) async => throw Exception('fail');
      await OutboxService.enqueueUpload('rec1');
      const id = 'ipfs_upload:rec1';

      final expectedSeconds = [30, 60, 120, 240];
      for (final expected in expectedSeconds) {
        final before = DateTime.now();
        await OutboxService.process();
        final next = DateTime.parse(job(id)['nextAttemptAt'] as String);
        expect(next.difference(before).inSeconds,
            inInclusiveRange(expected - 1, expected + 1));
        await makeDue(id);
      }

      // 30 s * 2^10 is far beyond the cap.
      await box.put(id, job(id)..['attempts'] = 10);
      final before = DateTime.now();
      await OutboxService.process();
      final next = DateTime.parse(job(id)['nextAttemptAt'] as String);
      expect(next.difference(before).inMinutes, inInclusiveRange(59, 60));
    });

    test('a job is marked failed after 20 attempts and never runs again', () async {
      var calls = 0;
      OutboxService.dispatchOverride = (_, __) async {
        calls++;
        throw Exception('permanent');
      };
      await OutboxService.enqueueUpload('rec1');
      const id = 'ipfs_upload:rec1';
      await box.put(id, job(id)..['attempts'] = 18);

      await OutboxService.process();
      expect(job(id)['attempts'], 19);
      expect(job(id)['failed'], false);

      await makeDue(id);
      await OutboxService.process();
      expect(job(id)['attempts'], 20);
      expect(job(id)['failed'], true);

      await makeDue(id);
      await OutboxService.process();
      expect(calls, 2);
      expect(job(id)['attempts'], 20);
    });

    test('JobNotReady leaves the job queued without using an attempt', () async {
      OutboxService.dispatchOverride =
          (_, __) async => throw const JobNotReady();
      await OutboxService.enqueueMeshRelay('rec1', 'nodeA');
      const id = 'mesh_relay:rec1:nodeA';
      final before = job(id);

      await OutboxService.process();

      expect(job(id), before);
    });

    test('one failing job does not block the others', () async {
      OutboxService.dispatchOverride = (type, payload) async {
        if (type == OutboxService.jobUpload) throw Exception('upload failed');
        dispatched.add((type, payload));
      };
      await OutboxService.enqueueUpload('rec1');
      await OutboxService.enqueueKeyShare('rec1', 'nodeA');

      await OutboxService.process();

      expect(box.keys.toList(), ['ipfs_upload:rec1']);
      expect(dispatched.single.$1, OutboxService.jobKeyShare);
    });

    test('an unknown job type is retried as a failure', () async {
      OutboxService.dispatchOverride = null;
      await OutboxService.enqueue('weird:1', 'not_a_type', {'recordKey': 'x'});

      await OutboxService.process();

      expect(job('weird:1')['attempts'], 1);
      expect(job('weird:1')['lastError'], contains('Unknown outbox job type'));
    });

    test('a process call made during a run triggers a rerun', () async {
      // An upload that succeeds and queues the anchor, as the vault does,
      // then pokes the outbox while it is still processing.
      OutboxService.dispatchOverride = (type, payload) async {
        dispatched.add((type, payload));
        if (type == OutboxService.jobUpload) {
          await OutboxService.enqueueAnchor(payload['recordKey'] as String);
          await OutboxService.process();
        }
      };
      await OutboxService.enqueueUpload('rec1');

      await OutboxService.process();

      expect(dispatched.map((d) => d.$1).toList(),
          [OutboxService.jobUpload, OutboxService.jobAnchor]);
      expect(box.isEmpty, isTrue);
    });
  });

  group('retryAllNow', () {
    test('makes backed-off jobs due but leaves failed jobs alone', () async {
      OutboxService.dispatchOverride = (_, __) async => throw Exception('offline');
      await OutboxService.enqueueUpload('rec1');
      await OutboxService.enqueueUpload('rec2');
      await OutboxService.process();
      await box.put('ipfs_upload:rec2', job('ipfs_upload:rec2')..['failed'] = true);

      OutboxService.dispatchOverride = (type, payload) async {
        dispatched.add((type, payload));
      };
      await OutboxService.process();
      expect(dispatched, isEmpty, reason: 'still inside the 30 s backoff');

      await OutboxService.retryAllNow();
      await OutboxService.process();

      expect(dispatched.single.$2['recordKey'], 'rec1');
      expect(box.containsKey('ipfs_upload:rec1'), isFalse);
      expect(job('ipfs_upload:rec2')['failed'], true);
    });
  });

  group('pending mesh jobs', () {
    test('only live mesh jobs count', () async {
      await OutboxService.enqueueUpload('rec1');
      await OutboxService.enqueueAnchor('rec1');
      expect(OutboxService.hasPendingMeshJobs(), isFalse);

      await OutboxService.enqueueMeshRelay('rec1', 'nodeA');
      expect(OutboxService.hasPendingMeshJobs(), isTrue);

      const id = 'mesh_relay:rec1:nodeA';
      await box.put(id, job(id)..['failed'] = true);
      expect(OutboxService.hasPendingMeshJobs(), isFalse);

      await OutboxService.enqueueKeyShare('rec1', 'nodeA');
      expect(OutboxService.hasPendingMeshJobs(), isTrue);
    });
  });
}
