import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class PinataUploadException implements Exception {
  final String message;
  PinataUploadException(this.message);

  @override
  String toString() => message;
}

class PinataService {
  static const String _pinataApiUrl = 'https://api.pinata.cloud/pinning/pinFileToIPFS';

  // Some networks silently drop large POSTs instead of rejecting them, which
  // otherwise looks like an infinite hang. Budget assumes a ~2 Mbps floor so
  // slow-but-working uploads still finish.
  static const Duration _baseTimeout = Duration(seconds: 30);
  static const int _minBytesPerSecond = 256 * 1024;

  static Duration uploadTimeoutFor(int fileBytes) =>
      _baseTimeout + Duration(seconds: fileBytes ~/ _minBytesPerSecond);

  /// Returns the CID, or throws [PinataUploadException] with a user-facing reason.
  static Future<String> uploadToIPFS(String filePath) async {
    final jwt = dotenv.env['PINATA_JWT'];
    if (jwt == null || jwt.isEmpty) {
      throw PinataUploadException('Pinata JWT not configured in .env');
    }

    final file = File(filePath);
    final timeout = uploadTimeoutFor(await file.length());

    final request = http.MultipartRequest('POST', Uri.parse(_pinataApiUrl))
      ..headers['Authorization'] = 'Bearer $jwt'
      ..files.add(await http.MultipartFile.fromPath('file', filePath));

    // A dedicated client so a timeout can close the socket rather than
    // leaving the upload running in the background.
    final client = http.Client();
    try {
      final response = await client.send(request).timeout(timeout);
      final body = await response.stream.bytesToString().timeout(_baseTimeout);

      if (response.statusCode != 200) {
        throw PinataUploadException(
          'Pinata rejected the upload (HTTP ${response.statusCode})',
        );
      }

      final cid = (jsonDecode(body) as Map<String, dynamic>)['IpfsHash'];
      if (cid is! String || cid.isEmpty) {
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
}
