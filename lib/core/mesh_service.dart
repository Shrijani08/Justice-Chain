import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'app_services.dart';

class MeshService {
  MeshService._internal();
  static final MeshService instance = MeshService._internal();
  factory MeshService() => instance;

  static const String serviceId = "org.justicechain.mesh";
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  final Map<String, String> _connectedEndpoints = {};
  String? _pendingMetadataJson;

  /// Start Advertising (Victim Mode - Offloading Evidence)
  Future<void> startAdvertising(String victimId, String encryptedFilePath, String fileHash) async {
    try {
      await Nearby().startAdvertising(
        victimId,
        strategy,
        onConnectionInitiated: (endpointId, connectionInfo) async {
          developer.log('🔗 Mesh connection initiated by: ${connectionInfo.endpointName}', name: 'JusticeChain.Mesh');
          // Auto-accept trusted connection
          await Nearby().acceptConnection(
            endpointId,
            onPayLoadRecieved: _onPayloadReceived,
            onPayloadTransferUpdate: _onPayloadTransferUpdate,
          );
        },
        onConnectionResult: (endpointId, status) async {
          if (status == Status.CONNECTED) {
            _connectedEndpoints[endpointId] = victimId;
            developer.log('✅ Connected to Guardian Node: $endpointId', name: 'JusticeChain.Mesh');

            // 1. Prepare and Send Metadata Payload
            final metadata = jsonEncode({
              'type': 'EVIDENCE_METADATA',
              'hash': fileHash,
              'victimId': victimId,
              'timestamp': DateTime.now().toIso8601String(),
              'fileName': encryptedFilePath.split('/').last,
            });

            await Nearby().sendBytesPayload(endpointId, utf8.encode(metadata));

            // 2. Send Encrypted File Payload
            await Nearby().sendFilePayload(endpointId, encryptedFilePath);
          }
        },
        onDisconnected: (endpointId) {
          _connectedEndpoints.remove(endpointId);
        },
        serviceId: serviceId,
      );
    } catch (e) {
      logger.e("Failed to start advertising mesh node: $e");
    }
  }

  /// Start Discovery (Guardian Mode - Listening for Distress Signals)
  Future<void> startDiscovery(String guardianId) async {
    try {
      await Nearby().startDiscovery(
        guardianId,
        strategy,
        onEndpointFound: (endpointId, name, serviceId) async {
          developer.log('🚨 Victim Node Discovered: $name ($endpointId)', name: 'JusticeChain.Mesh');
          await Nearby().requestConnection(
            guardianId,
            endpointId,
            onConnectionInitiated: (id, info) async {
              await Nearby().acceptConnection(
                id,
                onPayLoadRecieved: _onPayloadReceived,
                onPayloadTransferUpdate: _onPayloadTransferUpdate,
              );
            },
            onConnectionResult: (id, status) {
              if (status == Status.CONNECTED) {
                developer.log('✅ Connected to Victim Node: $id', name: 'JusticeChain.Mesh');
              }
            },
            onDisconnected: (id) {},
          );
        },
        onEndpointLost: (endpointId) {},
        serviceId: serviceId,
      );
    } catch (e) {
      logger.e("Failed to start discovery: $e");
    }
  }

  /// Handle incoming payload packets
  void _onPayloadReceived(String endpointId, Payload payload) async {
    if (payload.type == PayloadType.BYTES) {
      _pendingMetadataJson = utf8.decode(payload.bytes!);
      developer.log('📦 Metadata Received: $_pendingMetadataJson', name: 'JusticeChain.Mesh');
    } else if (payload.type == PayloadType.FILE) {
      developer.log('📄 File Payload Receiving: ${payload.id}', name: 'JusticeChain.Mesh');
      if (payload.uri != null && _pendingMetadataJson != null) {
        final meta = jsonDecode(_pendingMetadataJson!);
        final extDir = await getApplicationDocumentsDirectory();
        final destinationPath = '${extDir.path}/guardian_vault/${meta['fileName']}';

        await Directory('${extDir.path}/guardian_vault').create(recursive: true);
        await Nearby().copyFileAndDeleteOriginal(payload.uri!, destinationPath);

        developer.log('🔒 Evidence saved to Guardian Vault: $destinationPath', name: 'JusticeChain.Mesh');
        _pendingMetadataJson = null; // Clear queue
      }
    }
  }

  void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (update.status == PayloadStatus.SUCCESS) {
      developer.log('🎉 Payload transfer complete with endpoint: $endpointId', name: 'JusticeChain.Mesh');
    }
  }

  Future<void> stopAll() async {
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    await Nearby().stopAllEndpoints();
  }
}