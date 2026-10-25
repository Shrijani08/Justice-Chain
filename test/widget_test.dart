import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/main.dart';

import 'helpers/app_fonts.dart';

void main() {
  setUpAll(loadAppFonts);

  // Onboarding loops forever (orb, bars), so step time instead of settling.
  Future<void> advance(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // The canvas's phone, and a small one. A layout overflow fails the test.
  for (final (name, size) in const [('390x844', Size(390, 844)), ('360x640', Size(360, 640))]) {
    testWidgets('Onboarding walks to identity setup on a $name phone', (WidgetTester tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const JusticeChainApp(isRegistered: false));
      await advance(tester);
      expect(find.text('Your silent\nwitness.'), findsOneWidget);

      // Every page, one Next at a time.
      for (final title in ['It listens\nfor you.', 'Or tap SOS.', 'Proof is\nsealed.', 'Guardians\nhold the key.', 'Hide it in\nplain sight.', '4 quick steps.']) {
        await tester.tap(find.text('Next').hitTestable());
        await advance(tester);
        expect(find.text(title), findsOneWidget);
      }

      await tester.ensureVisible(find.text('Get started'));
      await tester.pump();
      await tester.tap(find.text('Get started'));
      await advance(tester);
      expect(find.text('Create your identity'), findsOneWidget);
      expect(find.text('Vault PIN · 4–6 digits'), findsOneWidget);
      expect(find.text('Confirm PIN'), findsOneWidget);
      expect(find.text('Generate secure keys'), findsOneWidget);

      // Back returns to the last onboarding page.
      await tester.tap(find.bySemanticsLabel('Back').hitTestable());
      await advance(tester);
      expect(find.text('4 quick steps.'), findsOneWidget);
    });
  }
}
