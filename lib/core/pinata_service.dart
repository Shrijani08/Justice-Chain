import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class PinataService {
  // Pinata's official endpoint for uploading files
  static const String _pinataApiUrl = 'https://api.pinata.cloud/pinning/pinFileToIPFS';

  static Future<String?> uploadToIPFS(String filePath) async {
    try {
      // 1. Safely grab your secret key from the .env file
      final jwt = dotenv.env['PINATA_JWT'];
      if (jwt == null) throw Exception('Pinata JWT not found in .env');

      // 2. Prepare the HTTP request
      var request = http.MultipartRequest('POST', Uri.parse(_pinataApiUrl));
      
      // 3. Attach your secret key for authorization
      request.headers.addAll({
        'Authorization': 'Bearer $jwt',
      });

      // 4. Attach the emergency video file
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      print('Uploading file to decentralized storage (IPFS)...');

      // 5. Fire it off to IPFS!
      var response = await request.send();
      var responseData = await response.stream.bytesToString();

      // 6. Check if it worked and return the CID
      if (response.statusCode == 200) {
        var json = jsonDecode(responseData);
        String cid = json['IpfsHash'];
        print('SUCCESS! File uploaded to IPFS. CID: $cid');
        return cid; 
      } else {
        print('Upload failed: ${response.statusCode} - $responseData');
        return null;
      }
    } catch (e) {
      print('Error connecting to Pinata: $e');
      return null;
    }
  }
}