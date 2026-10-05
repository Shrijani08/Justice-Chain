import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_sig;
import 'package:nearby_connections/nearby_connections.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:developer' as developer;
import '../logic/guardian_manager.dart';
import '../logic/safety_signals.dart';
import 'anchoring_service.dart';
import 'evidence_encryptor.dart';
import 'identity_service.dart';
import 'outbox_service.dart';

/// One-hop offline relay to paired guardians over Nearby Connections
/// (blueprint "Offline mesh relay"). Only ciphertext and signed manifests
/// ever cross the link.
///
/// Wire messages are bytes payloads tagged by prefix:
/// - `JCKS1:` a sealed guardian key share
/// - `JCMF1:` a signed relay manifest naming the file payload it covers
/// - `JCAK1:` a guardian's acknowledgement that a clip was verified and stored
class MeshService {
  // P2P_CLUSTER allows multiple devices to connect to each other in a mesh topology
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  // A unique identifier for the Justice-Chain app to prevent seeing other Nearby apps
  static const String _serviceId = "com.justicechain.mesh";

  static const String receivedSharesBoxName = 'received_shares_box';
  static const String relayBoxName = 'relay_box';

  static const String _keySharePrefix = 'JCKS1:';
  static const String _manifestPrefix = 'JCMF1:';
  static const String _ackPrefix = 'JCAK1:';
  static const String _shareForwardPrefix = 'JCKF1:';

  /// How long to wait for a guardian's ack before resending a clip.
  static const Duration _ackTimeout = Duration(minutes: 3);

  // Trusted node ID <-> Nearby endpoint ID for currently connected peers.
  static final Map<String, String> _endpointToNodeId = {};
  static final Map<String, String> _connectedNodes = {};

  // Receiver-side pairing of file payloads with their manifests, which may
  // arrive in either order. A file is only kept once a valid manifest for
  // it exists — never on the strength of the file alone.
  static final Map<int, ({String endpointId, String location, bool isUri})> _incomingFiles = {};
  static final Set<int> _completedFiles = {};
  static final Map<int, ({String endpointId, Map<String, dynamic> manifest})> _incomingManifests = {};

  static bool _advertising = false;
  static bool _discovering = false;

  static Future<String> _getLocalNodeId() => IdentityService.getMyNodeId();

  // ==========================================
  // 1. ADVERTISING (The Victim / Sender)
  // ==========================================

  /// Broadcasts this device's node ID so nearby guardians can connect.
  /// Idempotent.
  static Future<void> startAdvertising() async {
    if (_advertising) return;
    try {
      final localNodeId = await _getLocalNodeId();
      _advertising = await Nearby().startAdvertising(
        localNodeId,
        strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      if (_advertising) {
        developer.log('📡 Advertising started. Broadcasting Node ID: $localNodeId', name: 'JusticeChain.Mesh');
      }
    } catch (e) {
      developer.log('🚨 Failed to start advertising', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static Future<void> stopAdvertising() async {
    if (!_advertising) return;
    await Nearby().stopAdvertising();
    _advertising = false;
    developer.log('🔇 Stopped advertising.', name: 'JusticeChain.Mesh');
  }

  /// Stops advertising when there's nothing left to hand to a guardian,
  /// unless an incident is being recorded right now.
  static Future<void> stopAdvertisingIfIdle() async {
    if (isRecording.value) return;
    await stopAdvertising();
  }

  // ==========================================
  // 2. DISCOVERY (The Guardian / Receiver)
  // ==========================================

  /// Listens for paired devices in distress. Runs while the app is open.
  static Future<void> startDiscovery() async {
    if (_discovering) return;
    try {
      _discovering = await Nearby().startDiscovery(
        _serviceId,
        strategy,
        onEndpointFound: (endpointId, endpointName, serviceId) {
          // CRITICAL SECURITY: Only connect to node IDs in our whitelist.
          if (!GuardianManager.isTrusted(endpointName)) {
            developer.log('🛑 Unknown device ignored.', name: 'JusticeChain.Mesh');
            return;
          }
          if (_connectedNodes.containsKey(endpointName)) return;
          developer.log('🛡️ Trusted node $endpointName nearby. Connecting...', name: 'JusticeChain.Mesh');
          _requestConnection(endpointId);
        },
        onEndpointLost: (endpointId) {
          developer.log('📉 Lost endpoint: $endpointId', name: 'JusticeChain.Mesh');
        },
      );
      if (_discovering) {
        developer.log('📡 Discovery started. Listening for trusted nodes...', name: 'JusticeChain.Mesh');
      }
    } catch (e) {
      developer.log('🚨 Failed to start discovery', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static Future<void> stopDiscovery() async {
    if (!_discovering) return;
    await Nearby().stopDiscovery();
    _discovering = false;
    developer.log('🔇 Stopped discovery.', name: 'JusticeChain.Mesh');
  }

  // ==========================================
  // 3. CONNECTION HANDLERS (The Handshake)
  // ==========================================

  static Future<void> _requestConnection(String endpointId) async {
    final localNodeId = await _getLocalNodeId();
    try {
      await Nearby().requestConnection(
        localNodeId,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      developer.log('🚨 Connection request failed', error: e, name: 'JusticeChain.Mesh');
    }
  }

  /// Both sides check the peer against their own whitelist before accepting.
  static void _onConnectionInitiated(String endpointId, ConnectionInfo info) async {
    if (GuardianManager.isTrusted(info.endpointName)) {
      developer.log('✅ Identity verified. Accepting ${info.endpointName}.', name: 'JusticeChain.Mesh');
      _endpointToNodeId[endpointId] = info.endpointName;
      await Nearby().acceptConnection(
        endpointId,
        onPayLoadRecieved: _onPayloadReceived,
        onPayloadTransferUpdate: _onPayloadTransferUpdate,
      );
    } else {
      developer.log('❌ UNTRUSTED IDENTITY. Rejecting connection.', name: 'JusticeChain.Mesh');
      await Nearby().rejectConnection(endpointId);
    }
  }

  static void _onConnectionResult(String endpointId, Status status) {
    switch (status) {
      case Status.CONNECTED:
        final peerNodeId = _endpointToNodeId[endpointId];
        developer.log('🔗 SECURE MESH LINK ESTABLISHED with $peerNodeId', name: 'JusticeChain.Mesh');
        if (peerNodeId != null) {
          _connectedNodes[peerNodeId] = endpointId;
          // Flush clips and key shares queued for this peer while out of range.
          unawaited(OutboxService.process());
        }
        break;
      case Status.REJECTED:
        developer.log('🚫 Connection rejected by $endpointId', name: 'JusticeChain.Mesh');
        _forgetEndpoint(endpointId);
        break;
      case Status.ERROR:
        developer.log('⚠️ Connection error with $endpointId', name: 'JusticeChain.Mesh');
        _forgetEndpoint(endpointId);
        break;
    }
  }

  static void _onDisconnected(String endpointId) {
    developer.log('💔 Disconnected from $endpointId', name: 'JusticeChain.Mesh');
    _forgetEndpoint(endpointId);
  }

  static void _forgetEndpoint(String endpointId) {
    final nodeId = _endpointToNodeId.remove(endpointId);
    if (nodeId != null && _connectedNodes[nodeId] == endpointId) {
      _connectedNodes.remove(nodeId);
    }
  }

  static Future<void> _sendTagged(String endpointId, String prefix, Map<String, dynamic> body) {
    final encoded = base64Encode(utf8.encode(jsonEncode(body)));
    return Nearby().sendBytesPayload(
      endpointId,
      Uint8List.fromList(utf8.encode('$prefix$encoded')),
    );
  }

  static Map<String, dynamic> _decodeTagged(String encoded) =>
      jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>;

  // ==========================================
  // 4. SENDER: KEY SHARES & CLIP RELAY (Outbox handlers)
  // ==========================================

  /// Sends one guardian their sealed key share for one incident. Throws
  /// [JobNotReady] when that guardian isn't connected, so the outbox keeps
  /// it queued until they come into range.
  static Future<void> deliverKeyShare(String recordKey, String guardianNodeId) async {
    final record = Hive.box('vault_box').get(recordKey);
    if (record is! Map) return;
    final sealedShare = (record['guardianShares'] as Map?)?[guardianNodeId];
    if (sealedShare == null) return;

    final endpointId = _connectedNodes[guardianNodeId];
    if (endpointId == null) throw const JobNotReady();

    final ownNodeId = await _getLocalNodeId();
    await _sendTagged(endpointId, _keySharePrefix, {
      'manifestHash': recordKey,
      'victimNodeId': ownNodeId,
      'senderNodeId': ownNodeId,
      'senderX25519': await _ownX25519PublicKeyB64(),
      'sealedShare': sealedShare,
      'cid': record['cid'],
      'capturedAt': record['timestamp'],
      // Victim's Ed25519 signature over the plaintext hash, so the guardian
      // can later prove this device produced the clip.
      'signature': record['signature'],
      'quorum': EvidenceEncryptor.guardianQuorum,
    });
    developer.log('🔑 Key share for $recordKey sent to $guardianNodeId', name: 'JusticeChain.Mesh');
  }

  static Future<String> _ownX25519PublicKeyB64() async {
    final publicKey = await (await IdentityService.getX25519KeyPair()).extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Guardian side, after the user explicitly approves it: unseals this
  /// device's own share for [manifestHash] and re-seals it to co-guardian
  /// [toNodeId], so the two of them reach the quorum together.
  static Future<void> forwardShare(String manifestHash, String toNodeId) async {
    final ownNodeId = await _getLocalNodeId();
    final sharesBox = Hive.box(receivedSharesBoxName);
    final own = sharesBox.values
        .whereType<Map>()
        .where((s) => s['manifestHash'] == manifestHash && s['forwardedBy'] == null)
        .firstOrNull;
    if (own == null) return;

    final recipient = GuardianManager.getTrustedGuardians()[toNodeId];
    final recipientKey = recipient is Map ? recipient['x25519_public_key'] as String? : null;
    if (recipientKey == null) return;

    final endpointId = _connectedNodes[toNodeId];
    if (endpointId == null) throw const JobNotReady();

    final share = await EvidenceEncryptor.unsealGuardianShare(
      sealedShareB64: own['sealedShare'] as String,
      ownX25519KeyPair: await IdentityService.getX25519KeyPair(),
      senderX25519PublicKeyB64: own['senderX25519'] as String,
    );

    await _sendTagged(endpointId, _shareForwardPrefix, {
      ...Map<String, dynamic>.from(own)..remove('receivedAt'),
      'senderNodeId': ownNodeId,
      'senderX25519': await _ownX25519PublicKeyB64(),
      'sealedShare': await EvidenceEncryptor.sealShare(share, recipientKey),
      'forwardedBy': ownNodeId,
    });
    developer.log('🤝 Forwarded my share of $manifestHash to $toNodeId', name: 'JusticeChain.Mesh');
  }

  /// The exact bytes a relay manifest's Ed25519 signature covers.
  static List<int> _manifestSigningBytes(Map<String, dynamic> m) => utf8.encode(
        [
          'jc-relay-manifest-v1',
          m['manifestHash'],
          m['cipherHash'],
          m['capturedAt'],
          m['nodeId'],
          m['anchorSig'],
        ].join('|'),
      );

  /// Hands one encrypted clip to one guardian: file payload plus a signed
  /// manifest. Completes only once the guardian acks it; resends if no ack
  /// arrives within [_ackTimeout]. Skipped once the victim's own upload is
  /// anchored, since the relay would add nothing.
  static Future<void> relayClip(String recordKey, String guardianNodeId) async {
    final vaultBox = Hive.box('vault_box');
    final raw = vaultBox.get(recordKey);
    if (raw is! Map) return;
    final record = Map<String, dynamic>.from(raw);

    final deliveredTo = List<String>.from(record['meshDeliveredTo'] as List? ?? const []);
    if (deliveredTo.contains(guardianNodeId) || record['status'] == 'anchored') return;

    final cipherFile = File(record['path'] as String);
    if (!await cipherFile.exists()) return;

    final endpointId = _connectedNodes[guardianNodeId];
    if (endpointId == null) throw const JobNotReady();

    final sentAt = DateTime.tryParse(
      (record['meshSentAt'] as Map?)?[guardianNodeId] as String? ?? '',
    );
    if (sentAt != null && DateTime.now().difference(sentAt) < _ackTimeout) {
      throw const JobNotReady();
    }

    final cipherHash = record['cipherHash'] as String? ??
        sha256.convert(await cipherFile.readAsBytes()).toString();

    final manifest = <String, dynamic>{
      'manifestHash': recordKey,
      'cipherHash': cipherHash,
      'capturedAt': record['timestamp'],
      'nodeId': await _getLocalNodeId(),
      'anchorSig': await AnchoringService.signAnchor(recordKey),
    };
    manifest['signature'] = await IdentityService.signBytes(_manifestSigningBytes(manifest));

    final payloadId = await Nearby().sendFilePayload(endpointId, cipherFile.path);
    await _sendTagged(endpointId, _manifestPrefix, {'payloadId': payloadId, 'manifest': manifest});

    record['cipherHash'] = cipherHash;
    record['meshSentAt'] = {
      ...Map<String, dynamic>.from(record['meshSentAt'] as Map? ?? const {}),
      guardianNodeId: DateTime.now().toIso8601String(),
    };
    await vaultBox.put(recordKey, record);
    developer.log('🚀 Clip $recordKey sent to $guardianNodeId, awaiting ack', name: 'JusticeChain.Mesh');

    throw const JobNotReady();
  }

  static Future<void> _handleAck(String endpointId, String encoded) async {
    final nodeId = _endpointToNodeId[endpointId];
    if (nodeId == null) return;
    final recordKey = _decodeTagged(encoded)['manifestHash'] as String;

    final vaultBox = Hive.box('vault_box');
    final raw = vaultBox.get(recordKey);
    if (raw is! Map) return;
    final record = Map<String, dynamic>.from(raw);
    final deliveredTo = {...List<String>.from(record['meshDeliveredTo'] as List? ?? const []), nodeId};
    record['meshDeliveredTo'] = deliveredTo.toList();
    await vaultBox.put(recordKey, record);

    developer.log('📬 Guardian $nodeId confirmed clip $recordKey', name: 'JusticeChain.Mesh');
    appStatus.value = "Evidence handed to a nearby guardian";
    unawaited(OutboxService.process());
  }

  // ==========================================
  // 5. PAYLOAD HANDLERS
  // ==========================================

  static void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.FILE) {
      // Android 11+ delivers a content URI; older versions a file path.
      final uri = payload.uri;
      // ignore: deprecated_member_use
      final path = payload.filePath;
      final location = uri ?? path;
      if (location == null) return;
      _incomingFiles[payload.id] = (endpointId: endpointId, location: location, isUri: uri != null);
      return;
    }

    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    final message = utf8.decode(payload.bytes!, allowMalformed: true);

    if (message.startsWith(_keySharePrefix)) {
      _storeReceivedKeyShare(endpointId, message.substring(_keySharePrefix.length));
    } else if (message.startsWith(_shareForwardPrefix)) {
      _storeReceivedKeyShare(endpointId, message.substring(_shareForwardPrefix.length));
    } else if (message.startsWith(_manifestPrefix)) {
      _storeIncomingManifest(endpointId, message.substring(_manifestPrefix.length));
    } else if (message.startsWith(_ackPrefix)) {
      _handleAck(endpointId, message.substring(_ackPrefix.length));
    }
  }

  static void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    switch (update.status) {
      case PayloadStatus.SUCCESS:
        if (_incomingFiles.containsKey(update.id)) {
          _completedFiles.add(update.id);
          unawaited(_tryFinalizeRelay(update.id));
        }
      case PayloadStatus.FAILURE:
      case PayloadStatus.CANCELED:
        developer.log('🚨 Payload ${update.id} transfer failed.', name: 'JusticeChain.Mesh');
        _incomingFiles.remove(update.id);
        _incomingManifests.remove(update.id);
      default:
        break;
    }
  }

  static Future<void> _storeReceivedKeyShare(String endpointId, String encoded) async {
    try {
      final message = _decodeTagged(encoded);
      final senderNodeId = message['senderNodeId'] as String;

      // The share must come from the trusted peer actually on this link.
      if (_endpointToNodeId[endpointId] != senderNodeId) {
        developer.log('🛑 Key share sender mismatch — dropped.', name: 'JusticeChain.Mesh');
        return;
      }

      // Direct shares come from the victim; forwarded ones from a co-guardian.
      final key = message['forwardedBy'] == null
          ? '${message['manifestHash']}:$senderNodeId'
          : '${message['manifestHash']}:fwd:$senderNodeId';
      await Hive.box(receivedSharesBoxName).put(key, {
        ...message,
        'receivedAt': DateTime.now().toIso8601String(),
      });
      developer.log('🔑 Key share received from $senderNodeId', name: 'JusticeChain.Mesh');
    } catch (e) {
      developer.log('🚨 Malformed key share payload', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static void _storeIncomingManifest(String endpointId, String encoded) {
    try {
      final message = _decodeTagged(encoded);
      final payloadId = message['payloadId'] as int;
      _incomingManifests[payloadId] = (
        endpointId: endpointId,
        manifest: Map<String, dynamic>.from(message['manifest'] as Map),
      );
      unawaited(_tryFinalizeRelay(payloadId));
    } catch (e) {
      developer.log('🚨 Malformed relay manifest', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static Future<bool> _verifyManifestSignature(Map<String, dynamic> manifest) async {
    final sender = GuardianManager.getTrustedGuardians()[manifest['nodeId']];
    final publicKeyB64 = sender is Map ? sender['public_key'] as String? : null;
    if (publicKeyB64 == null) return false;

    return crypto_sig.Ed25519().verify(
      _manifestSigningBytes(manifest),
      signature: crypto_sig.Signature(
        base64Decode(manifest['signature'] as String),
        publicKey: crypto_sig.SimplePublicKey(
          base64Decode(publicKeyB64),
          type: crypto_sig.KeyPairType.ed25519,
        ),
      ),
    );
  }

  /// Runs once both the file and its manifest are in. Verifies the sender,
  /// the Ed25519 manifest signature (against the key saved at pairing) and
  /// the ciphertext hash before storing anything; acks the sender on success.
  static Future<void> _tryFinalizeRelay(int payloadId) async {
    final file = _incomingFiles[payloadId];
    final entry = _incomingManifests[payloadId];
    if (file == null || entry == null || !_completedFiles.contains(payloadId)) return;

    _incomingFiles.remove(payloadId);
    _incomingManifests.remove(payloadId);
    _completedFiles.remove(payloadId);

    final manifest = entry.manifest;
    final manifestHash = manifest['manifestHash'] as String;
    File? stored;

    try {
      final senderNodeId = _endpointToNodeId[entry.endpointId];
      if (senderNodeId == null ||
          senderNodeId != manifest['nodeId'] ||
          file.endpointId != entry.endpointId) {
        throw StateError('manifest sender does not match the connected peer');
      }
      if (!await _verifyManifestSignature(manifest)) {
        throw StateError('manifest signature invalid');
      }

      final docs = await getApplicationDocumentsDirectory();
      final relayDir = Directory('${docs.path}/JusticeChain/relayed');
      await relayDir.create(recursive: true);
      final destPath = '${relayDir.path}/$manifestHash.enc';

      if (file.isUri) {
        await Nearby().copyFileAndDeleteOriginal(file.location, destPath);
      } else {
        await File(file.location).copy(destPath);
        await File(file.location).delete();
      }
      stored = File(destPath);

      final actualHash = sha256.convert(await stored.readAsBytes()).toString();
      if (actualHash != manifest['cipherHash']) {
        throw StateError('ciphertext hash mismatch');
      }

      await Hive.box(relayBoxName).put(manifestHash, {
        ...manifest,
        'path': destPath,
        'status': 'relay_received',
        'cid': null,
        'receivedAt': DateTime.now().toIso8601String(),
      });

      await _sendTagged(entry.endpointId, _ackPrefix, {'manifestHash': manifestHash});
      developer.log('🛡️ Relayed clip $manifestHash verified and stored', name: 'JusticeChain.Mesh');

      await OutboxService.enqueueRelayUpload(manifestHash);
      unawaited(OutboxService.process());
    } catch (e) {
      developer.log('🚨 Rejected relayed clip $manifestHash: $e', name: 'JusticeChain.Mesh');
      if (stored != null && await stored.exists()) await stored.delete();
      if (!file.isUri && await File(file.location).exists()) {
        await File(file.location).delete();
      }
    }
  }
}
