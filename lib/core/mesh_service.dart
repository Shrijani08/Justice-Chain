import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as developer;
import '../logic/guardian_manager.dart';

class MeshService {
  // P2P_CLUSTER allows multiple devices to connect to each other in a mesh topology
  static const Strategy strategy = Strategy.P2P_CLUSTER;
  
  // A unique identifier for the Justice-Chain app to prevent seeing other Nearby apps
  static const String _serviceId = "com.justicechain.mesh";

  // In-memory mapping for tracking incoming file transfers & metadata
  static final Map<int, String> _incomingFileNames = {};
  static final Map<int, String> _incomingHashes = {};
  static final Map<int, String> _tempFilePaths = {};

  /// Gets the local device's Secure Node ID to broadcast to others
  static Future<String> _getLocalNodeId() async {
    final vaultBox = Hive.box('vault_box');
    return vaultBox.get('node_id', defaultValue: 'UNKNOWN_NODE');
  }

  // ==========================================
  // 1. ADVERTISING (The Victim / Sender)
  // ==========================================
  
  /// Call this when distress is detected and evidence is recorded.
  /// It broadcasts your Node ID to anyone listening.
  static Future<void> startAdvertising() async {
    try {
      final localNodeId = await _getLocalNodeId();
      
      bool advertising = await Nearby().startAdvertising(
        localNodeId, // We broadcast our Node ID as our "Name"
        strategy,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: _serviceId,
      );
      
      if (advertising) {
        developer.log('📡 Advertising started. Broadcasting Node ID: $localNodeId', name: 'JusticeChain.Mesh');
      }
    } catch (e) {
      developer.log('🚨 Failed to start advertising', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static Future<void> stopAdvertising() async {
    await Nearby().stopAdvertising();
    developer.log('🔇 Stopped advertising.', name: 'JusticeChain.Mesh');
  }

  // ==========================================
  // 2. DISCOVERY (The Guardian / Receiver)
  // ==========================================

  /// Call this when the app is open in the background to listen for friends in distress.
  static Future<void> startDiscovery() async {
    try {
      bool discovering = await Nearby().startDiscovery(
        _serviceId,
        strategy,
        onEndpointFound: (endpointId, endpointName, serviceId) {
          developer.log('🔍 Found device with Node ID: $endpointName', name: 'JusticeChain.Mesh');
          
          // CRITICAL SECURITY: Only request a connection if the Node ID is in our Vault!
          if (GuardianManager.isTrusted(endpointName)) {
            developer.log('🛡️ Trusted Guardian detected! Requesting secure connection...', name: 'JusticeChain.Mesh');
            _requestConnection(endpointId);
          } else {
            developer.log('🛑 Unknown device ignored.', name: 'JusticeChain.Mesh');
          }
        },
        onEndpointLost: (endpointId) {
          developer.log('📉 Lost connection to endpoint: $endpointId', name: 'JusticeChain.Mesh');
        },
      );
      
      if (discovering) {
        developer.log('📡 Discovery started. Listening for trusted nodes...', name: 'JusticeChain.Mesh');
      }
    } catch (e) {
      developer.log('🚨 Failed to start discovery', error: e, name: 'JusticeChain.Mesh');
    }
  }

  static Future<void> stopDiscovery() async {
    await Nearby().stopDiscovery();
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

  /// Triggered when two devices attempt to connect
  static void _onConnectionInitiated(String endpointId, ConnectionInfo info) async {
    developer.log('🤝 Connection initiated by: ${info.endpointName}', name: 'JusticeChain.Mesh');

    // Double-check authorization on BOTH sides before accepting
    if (GuardianManager.isTrusted(info.endpointName)) {
      developer.log('✅ Identity Verified. Accepting connection from $endpointId.', name: 'JusticeChain.Mesh');
      
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

  static void _onConnectionResult(String endpointId, Status status) async {
    switch (status) {
      case Status.CONNECTED:
        developer.log('🔗 SECURE MESH LINK ESTABLISHED with $endpointId', name: 'JusticeChain.Mesh');
        
        // Retrieve evidence to dispatch
        final vaultBox = Hive.box('vault_box');
        final recentEvidence = vaultBox.values
            .where((item) => item is Map && item['status'] == 'locally_secured')
            .toList();

        if (recentEvidence.isNotEmpty) {
          recentEvidence.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
          final targetEvidence = Map<String, dynamic>.from(recentEvidence.first);
          
          final String filePath = targetEvidence['path'];
          final String fileHash = targetEvidence['hash'];
          final String fileName = filePath.split('/').last;

          developer.log('🚀 Initiating File Transfer: $fileName', name: 'JusticeChain.Mesh');

          // 1. Send video file payload
          int payloadId = await Nearby().sendFilePayload(endpointId, filePath);

          // 2. Send metadata payload: "payloadId:fileName:fileHash"
          String metadata = "$payloadId:$fileName:$fileHash";
          await Nearby().sendBytesPayload(
            endpointId,
            Uint8List.fromList(metadata.codeUnits),
          );
        }
        break;
      case Status.REJECTED:
        developer.log('🚫 Connection rejected by $endpointId', name: 'JusticeChain.Mesh');
        break;
      case Status.ERROR:
        developer.log('⚠️ Connection error with $endpointId', name: 'JusticeChain.Mesh');
        break;
    }
  }

  static void _onDisconnected(String endpointId) {
    developer.log('💔 Disconnected from $endpointId', name: 'JusticeChain.Mesh');
  }

  // ==========================================
  // 4. PAYLOAD HANDLERS (Data Transfer & Vaulting)
  // ==========================================

  static void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.FILE) {
      developer.log('📦 File payload incoming ID: ${payload.id}', name: 'JusticeChain.Mesh');
      if (payload.filePath != null) {
        _tempFilePaths[payload.id] = payload.filePath!;
      }
    } else if (payload.type == PayloadType.BYTES) {
      String metadata = String.fromCharCodes(payload.bytes!);
      List<String> parts = metadata.split(':');
      
      if (parts.length == 3) {
        int targetPayloadId = int.parse(parts[0]);
        String expectedName = parts[1];
        String expectedHash = parts[2];

        _incomingFileNames[targetPayloadId] = expectedName;
        _incomingHashes[targetPayloadId] = expectedHash;
        
        developer.log('🏷️ Metadata recorded for payload $targetPayloadId: $expectedName', name: 'JusticeChain.Mesh');
      }
    }
  }

  static void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) async {
    if (update.status == PayloadStatus.SUCCESS) {
      developer.log('✅ Payload ${update.id} transfer COMPLETE!', name: 'JusticeChain.Mesh');
      
      // Check if this payload is an incoming video file
      if (_tempFilePaths.containsKey(update.id)) {
        await _processAndVaultIncomingFile(update.id);
      }
    } else if (update.status == PayloadStatus.IN_PROGRESS) {
      final percent = (update.bytesTransferred / update.totalBytes) * 100;
      developer.log('⏳ Payload ${update.id} Transferring: ${percent.toStringAsFixed(1)}%', name: 'JusticeChain.Mesh');
    } else if (update.status == PayloadStatus.FAILURE) {
      developer.log('🚨 Payload ${update.id} transfer FAILED.', name: 'JusticeChain.Mesh');
      _cleanupPayloadTrackers(update.id);
    }
  }

  /// Renames, verifies, and registers received relay evidence into Hive Vault
  static Future<void> _processAndVaultIncomingFile(int payloadId) async {
    final tempPath = _tempFilePaths[payloadId];
    final fileName = _incomingFileNames[payloadId] ?? "relayed_evidence_$payloadId.mp4";
    final expectedHash = _incomingHashes[payloadId];

    if (tempPath == null) return;

    try {
      final tempFile = File(tempPath);
      if (!await tempFile.exists()) return;

      // 1. Read bytes & Verify SHA-256 integrity
      final bytes = await tempFile.readAsBytes();
      final actualHash = sha256.convert(bytes).toString();

      if (expectedHash != null && actualHash != expectedHash) {
        developer.log('🚨 INTEGRITY CHECK FAILED! Hash mismatch on received file.', name: 'JusticeChain.Mesh');
        await tempFile.delete();
        _cleanupPayloadTrackers(payloadId);
        return;
      }

      // 2. Permanent storage destination in app directory
      final parentDir = tempFile.parent.path;
      final newPath = '$parentDir/$fileName';
      final permanentFile = await tempFile.rename(newPath);

      // 3. Register into Guardian's Hive Vault
      final vaultBox = Hive.box('vault_box');
      await vaultBox.add({
        'path': permanentFile.path,
        'hash': actualHash,
        'status': 'relay_received',
        'timestamp': DateTime.now().toIso8601String(),
        'source': 'mesh_relay',
      });

      developer.log('🛡️ Evidence verified & stored in Guardian Vault: ${permanentFile.path}', name: 'JusticeChain.Mesh');
    } catch (e) {
      developer.log('🚨 Error processing incoming file payload', error: e, name: 'JusticeChain.Mesh');
    } finally {
      _cleanupPayloadTrackers(payloadId);
    }
  }

  static void _cleanupPayloadTrackers(int payloadId) {
    _incomingFileNames.remove(payloadId);
    _incomingHashes.remove(payloadId);
    _tempFilePaths.remove(payloadId);
  }
}