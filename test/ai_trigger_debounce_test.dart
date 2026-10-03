import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/ai_service.dart';

// Regression coverage for the live-device bug: a single noisy window used to
// fire a recording instantly, and nothing reset between cycles, so the AI
// could retrigger the instant a recording ended — which on one real device
// hammered the camera until it threw a native CameraException. The fix
// requires 2 of the last 3 windows to clear threshold, and clears that
// history whenever monitoring (re)starts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AIService.instance eagerly constructs an AudioRecorder, which talks to
  // this platform channel. Stub it out so the singleton can be built in a
  // plain unit test without a real device/plugin.
  const recordChannel = MethodChannel('com.llfbandit.record/messages');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(recordChannel, (call) async => null);

  late AIService service;

  setUp(() {
    service = AIService.instance;
    service.resetWindowHistoryForTest();
  });

  test('a single passing window does not confirm distress', () {
    final confirmed = service.recordWindowPassForTest(true);
    expect(confirmed, isFalse);
  });

  test('two consecutive passing windows out of three confirms distress', () {
    expect(service.recordWindowPassForTest(true), isFalse);
    expect(service.recordWindowPassForTest(true), isTrue);
  });

  test('two passing windows separated by a quiet window still confirms', () {
    expect(service.recordWindowPassForTest(true), isFalse);
    expect(service.recordWindowPassForTest(false), isFalse);
    expect(service.recordWindowPassForTest(true), isTrue);
  });

  test('one passing window followed by two quiet windows does not confirm', () {
    expect(service.recordWindowPassForTest(true), isFalse);
    expect(service.recordWindowPassForTest(false), isFalse);
    expect(service.recordWindowPassForTest(false), isFalse);
  });

  test('history only looks at the last 3 windows, not all of history', () {
    // A single old pass, pushed out of the 3-window lookback by two quiet
    // windows, must not combine with a later single pass to confirm.
    expect(service.recordWindowPassForTest(true), isFalse);
    expect(service.recordWindowPassForTest(false), isFalse);
    expect(service.recordWindowPassForTest(false), isFalse);
    expect(service.recordWindowPassForTest(true), isFalse);
  });

  test('resetting history clears any partial buildup', () {
    expect(service.recordWindowPassForTest(true), isFalse);
    service.resetWindowHistoryForTest();
    // Without the reset, this second pass would combine with the one above
    // and incorrectly confirm.
    expect(service.recordWindowPassForTest(true), isFalse);
  });
}
