import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/main.dart';

void main() {
  testWidgets('Unregistered app shows registration screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const JusticeChainApp(isRegistered: false));

    expect(find.text('Initialize Node'), findsOneWidget);
    expect(find.text('Node Alias / Name'), findsOneWidget);
    expect(find.text('Vault PIN (4-6 digits)'), findsOneWidget);
    expect(find.text('Confirm PIN'), findsOneWidget);
    expect(find.text('GENERATE SECURE KEYS'), findsOneWidget);
  });
}
