import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

class IpfsService {
  // Your computer's IP address will go here.
  // DO NOT use localhost when the app runs on your phone.
  static const String backendUrl = 'http://192.168.0.100:3000';

  static Future<String> uploadFile(File file) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/upload'),
    );

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
      ),
    );

    final streamedResponse = await request.send();

    final response = await http.Response.fromStream(
      streamedResponse,
    );

    if (response.statusCode != 200) {
      throw Exception(
        'IPFS upload failed: ${response.body}',
      );
    }

    final data = jsonDecode(response.body);

    if (data['success'] != true || data['cid'] == null) {
      throw Exception(
        'Invalid response from backend: ${response.body}',
      );
    }

    return data['cid'];
  }
}