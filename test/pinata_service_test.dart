import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
