import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:justice_chain/core/pinata_service.dart';

void main() {
  group('uploadTimeoutFor', () {
    test('small files get the 30s base budget', () {
      expect(PinataService.uploadTimeoutFor(1024), const Duration(seconds: 30));
    });

    test('budget grows with file size so slow networks still finish', () {
      const fiftyMb = 50 * 1024 * 1024;
      expect(
        PinataService.uploadTimeoutFor(fiftyMb),
        const Duration(seconds: 30 + 200),
      );
    });
  });

  test('missing JWT throws a PinataUploadException instead of returning null', () async {
    dotenv.loadFromString(envString: 'UNRELATED=1');
    await expectLater(
      PinataService.uploadToIPFS('unused.mp4'),
      throwsA(isA<PinataUploadException>()),
    );
  });

  group('upload through a one-time URL from the gateway', () {
    tearDown(() {
      PinataService.uploadUrlForTest = null;
      PinataService.clientForTest = null;
    });

    test('sends the file to the signed URL with no Pinata key, and reads the v3 CID', () async {
      dotenv.loadFromString(envString: 'UNRELATED=1');
      final dir = await Directory.systemTemp.createTemp('pinata_test');
      final file = File('${dir.path}/clip.enc')..writeAsBytesSync(List<int>.filled(300, 7));
      int? askedSize;
      late http.BaseRequest sent;
      PinataService.uploadUrlForTest = (size) async {
        askedSize = size;
        return 'https://uploads.pinata.cloud/v3/files/signed-123';
      };
      PinataService.clientForTest = () => MockClient((request) async {
            sent = request;
            return http.Response('{"data":{"id":"x","cid":"bafkreiabc","size":300}}', 200);
          });

      expect(await PinataService.uploadToIPFS(file.path), 'bafkreiabc');
      expect(askedSize, 300);
      expect(sent.url.toString(), 'https://uploads.pinata.cloud/v3/files/signed-123');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      await dir.delete(recursive: true);
    });

    test('a gateway that will not give a URL is a clear upload error', () async {
      dotenv.loadFromString(envString: 'UNRELATED=1');
      final dir = await Directory.systemTemp.createTemp('pinata_test');
      final file = File('${dir.path}/clip.enc')..writeAsBytesSync([1, 2, 3]);
      PinataService.uploadUrlForTest = (_) async => throw StateError('Fabric gateway HTTP 401');

      await expectLater(
        PinataService.uploadToIPFS(file.path),
        throwsA(isA<PinataUploadException>().having((e) => e.message, 'message', contains('upload link'))),
      );
      await dir.delete(recursive: true);
    });
  });

  test('reads the CID from v3 and legacy replies', () {
    expect(PinataService.cidFromResponse({'data': {'cid': 'bafy1'}}), 'bafy1');
    expect(PinataService.cidFromResponse({'IpfsHash': 'Qm1'}), 'Qm1');
    expect(PinataService.cidFromResponse({'data': 'x'}), isNull);
  });
}
