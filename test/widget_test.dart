import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/main.dart';

void main() {
  testWidgets('App starts and shows initialization status', (WidgetTester tester) async {
    // 1. Build our app and trigger a frame.
    // We use JusticeChainApp() because that is what we defined in main.dart
    await tester.pumpWidget(const JusticeChainApp());

    // 2. Verify that the Sentinel title is present.
    expect(find.text('Justice-Chain Sentinel'), findsOneWidget);

    // 3. Verify that it starts by trying to initialize/check permissions
    // (It won't find "0" or "1" because the counter is gone!)
    expect(find.text('Initializing...'), findsOneWidget);
  });
}