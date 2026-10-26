import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'authority_service.dart';

class PinataUploadException implements Exception {
  final String message;
  PinataUploadException(this.message);

  @override
  String toString() => message;
}

/// Uploads encrypted clips to IPFS through Pinata. The phone holds no
/// Pinata key: the gateway hands it a one-time upload URL for each file
/// (POST /upload-url), so a copied APK can't upload to, list or delete
/// the project's pins (judge review finding S1). A PINATA_JWT in the app
/// config is used instead only by developer builds without a gateway.
class PinataService {
  static const String _legacyUrl = 'https://api.pinata.cloud/pinning/pinFileToIPFS';

  // Some networks silently drop large POSTs instead of rejecting them, which
  // otherwise looks like an infinite hang. Budget assumes a ~2 Mbps floor so
  // slow-but-working uploads still finish.
  static const Duration _baseTimeout = Duration(seconds: 30);
  static const int _minBytesPerSecond = 256 * 1024;

  static Duration uploadTimeoutFor(int fileBytes) =>
      _baseTimeout + Duration(seconds: fileBytes ~/ _minBytesPerSecond);

  /// Test seams: where a one-time upload URL comes from, and the client.
  @visibleForTesting
  static Future<String> Function(int size)? uploadUrlForTest;
  @visibleForTesting
  static http.Client Function()? clientForTest;

  static String? get _legacyJwt {
    final jwt = dotenv.isInitialized ? dotenv.env['PINATA_JWT']?.trim() : null;
    return jwt == null || jwt.isEmpty ? null : jwt;
  }

  /// Returns the CID, or throws [PinataUploadException] with a user-facing reason.
  static Future<String> uploadToIPFS(String filePath) async {
    final viaGateway = uploadUrlForTest != null || AuthorityService.ledgerFeaturesEnabled;
    if (!viaGateway && _legacyJwt == null) {
      throw PinataUploadException('No gateway (GATEWAY_URL) configured for uploads');
    }
    final file = File(filePath);
    final size = await file.length();
    final timeout = uploadTimeoutFor(size);

    final http.MultipartRequest request;
    if (viaGateway) {
      final String url;
      try {
        url = await (uploadUrlForTest ?? AuthorityService.requireGateway().uploadUrl)(size);
      } catch (e) {
        throw PinataUploadException('Could not get an upload link from the gateway: $e');
      }
      request = http.MultipartRequest('POST', Uri.parse(url))..fields['network'] = 'public';
    } else {
      request = http.MultipartRequest('POST', Uri.parse(_legacyUrl))..headers['Authorization'] = 'Bearer $_legacyJwt';
    }
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    // A dedicated client so a timeout can close the socket rather than
    // leaving the upload running in the background.
    final client = clientForTest?.call() ?? http.Client();
    try {
      final response = await client.send(request).timeout(timeout);
      final body = await response.stream.bytesToString().timeout(_baseTimeout);

      if (response.statusCode != 200) {
        throw PinataUploadException(
          'Pinata rejected the upload (HTTP ${response.statusCode})',
        );
      }

      final cid = cidFromResponse(jsonDecode(body));
      if (cid == null || cid.isEmpty) {
        throw PinataUploadException('Pinata response did not include a CID');
      }
      return cid;
    } on TimeoutException {
      throw PinataUploadException(
        'Upload timed out after ${timeout.inSeconds}s — network may be blocking large uploads',
      );
    } on SocketException catch (e) {
      throw PinataUploadException('No connection to Pinata: ${e.message}');
    } on http.ClientException catch (e) {
      throw PinataUploadException('Network error during upload: ${e.message}');
    } finally {
      client.close();
    }
  }

  /// The CID in a Pinata reply: v3 uploads answer {data: {cid}}, the legacy
  /// pinning API {IpfsHash}.
  @visibleForTesting
  static String? cidFromResponse(Object? json) {
    if (json is! Map) return null;
    final data = json['data'];
    if (data is Map && data['cid'] is String) return data['cid'] as String;
    return json['IpfsHash'] is String ? json['IpfsHash'] as String : null;
  }
}
