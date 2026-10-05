import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'evidence_vault_service.dart';
import 'mesh_service.dart';

/// Thrown by a job handler when the job can't run right now for a reason
/// that isn't a failure (e.g. the guardian isn't in mesh range). The job
/// stays queued without consuming a retry attempt.
class JobNotReady implements Exception {
  const JobNotReady();
}

/// Durable, retrying work queue persisted in Hive, so uploads, anchors and
/// guardian key-share deliveries survive app restarts and bad networks.
class OutboxService {
  OutboxService._();

  static const String boxName = 'outbox_box';
  static const String jobUpload = 'ipfs_upload';
  static const String jobAnchor = 'anchor';
  static const String jobKeyShare = 'key_share';
  static const String jobMeshRelay = 'mesh_relay';
  static const String jobRelayUpload = 'relay_upload';
  static const String jobShareForward = 'share_forward';

  static const Set<String> _meshJobTypes = {jobKeyShare, jobMeshRelay, jobShareForward};

  static const int _maxAttempts = 20;
  static const Duration _baseBackoff = Duration(seconds: 30);
  static const Duration _maxBackoff = Duration(hours: 1);

  static Box get _box => Hive.box(boxName);
  static Timer? _timer;
  static StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  static bool _processing = false;
  static bool _rerunRequested = false;

  static Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => process());
    _connectivitySub ??= Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) process();
    });
    unawaited(process());
  }

  /// Queues a job. [id] deduplicates: enqueueing an id that is already
  /// queued is a no-op.
  static Future<void> enqueue(
    String id,
    String type,
    Map<String, dynamic> payload,
  ) async {
    if (_box.containsKey(id)) return;
    await _box.put(id, {
      'type': type,
      'payload': payload,
      'attempts': 0,
      'nextAttemptAt': DateTime.now().toIso8601String(),
      'lastError': null,
      'failed': false,
    });
  }

  static Future<void> enqueueUpload(String recordKey) =>
      enqueue('$jobUpload:$recordKey', jobUpload, {'recordKey': recordKey});

  static Future<void> enqueueAnchor(String recordKey) =>
      enqueue('$jobAnchor:$recordKey', jobAnchor, {'recordKey': recordKey});

  static Future<void> enqueueKeyShare(String recordKey, String guardianNodeId) =>
      enqueue(
        '$jobKeyShare:$recordKey:$guardianNodeId',
        jobKeyShare,
        {'recordKey': recordKey, 'guardianNodeId': guardianNodeId},
      );

  static Future<void> enqueueMeshRelay(String recordKey, String guardianNodeId) =>
      enqueue(
        '$jobMeshRelay:$recordKey:$guardianNodeId',
        jobMeshRelay,
        {'recordKey': recordKey, 'guardianNodeId': guardianNodeId},
      );

  /// Guardian side: upload and anchor a clip relayed by a victim.
  static Future<void> enqueueRelayUpload(String manifestHash) => enqueue(
        '$jobRelayUpload:$manifestHash',
        jobRelayUpload,
        {'recordKey': manifestHash},
      );

  static Future<void> enqueueShareForward(String manifestHash, String toNodeId) =>
      enqueue(
        '$jobShareForward:$manifestHash:$toNodeId',
        jobShareForward,
        {'recordKey': manifestHash, 'toNodeId': toNodeId},
      );

  static bool _hasPendingMeshJobs() => _box.values.any(
        (job) =>
            job is Map &&
            job['failed'] != true &&
            _meshJobTypes.contains(job['type']),
      );

  /// Runs every due job once. Safe to call often; concurrent calls coalesce.
  static Future<void> process() async {
    if (_processing) {
      _rerunRequested = true;
      return;
    }
    _processing = true;
    try {
      do {
        _rerunRequested = false;
        for (final id in _box.keys.toList()) {
          await _runJob(id as String);
        }
      } while (_rerunRequested);

      // Stay visible to guardians only while something is waiting for one.
      if (_hasPendingMeshJobs()) {
        await MeshService.startAdvertising();
      } else {
        await MeshService.stopAdvertisingIfIdle();
      }
    } finally {
      _processing = false;
    }
  }

  static Future<void> _runJob(String id) async {
    final raw = _box.get(id);
    if (raw is! Map) return;
    final job = Map<String, dynamic>.from(raw);
    if (job['failed'] == true) return;

    final due = DateTime.tryParse(job['nextAttemptAt'] as String? ?? '');
    if (due != null && due.isAfter(DateTime.now())) return;

    final payload = Map<String, dynamic>.from(job['payload'] as Map);
    try {
      await _dispatch(job['type'] as String, payload);
      await _box.delete(id);
    } on JobNotReady {
      return;
    } catch (e) {
      final attempts = (job['attempts'] as int) + 1;
      final backoff = Duration(
        milliseconds: min(
          _baseBackoff.inMilliseconds * pow(2, attempts - 1).toInt(),
          _maxBackoff.inMilliseconds,
        ),
      );
      job['attempts'] = attempts;
      job['lastError'] = e.toString();
      job['nextAttemptAt'] = DateTime.now().add(backoff).toIso8601String();
      job['failed'] = attempts >= _maxAttempts;
      await _box.put(id, job);
      developer.log(
        'Outbox job $id failed (attempt $attempts): $e',
        name: 'JusticeChain.Outbox',
      );
    }
  }

  static Future<void> _dispatch(String type, Map<String, dynamic> payload) {
    final recordKey = payload['recordKey'] as String;
    switch (type) {
      case jobUpload:
        return EvidenceVaultService.uploadRecord(recordKey);
      case jobAnchor:
        return EvidenceVaultService.anchorRecord(recordKey);
      case jobKeyShare:
        return MeshService.deliverKeyShare(
          recordKey,
          payload['guardianNodeId'] as String,
        );
      case jobMeshRelay:
        return MeshService.relayClip(
          recordKey,
          payload['guardianNodeId'] as String,
        );
      case jobRelayUpload:
        return EvidenceVaultService.uploadRelayedClip(recordKey);
      case jobShareForward:
        return MeshService.forwardShare(recordKey, payload['toNodeId'] as String);
      default:
        throw StateError('Unknown outbox job type: $type');
    }
  }
}
