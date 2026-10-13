import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/logic/decoy_calculator.dart';

/// Presses each key of [keys] (a string of key labels) and returns the last result.
SecretEntry? type(DecoyCalculator c, String keys) {
  SecretEntry? last;
  for (final k in keys.split('')) {
    last = c.press(k);
  }
  return last;
}

void main() {
  group('works as a calculator', () {
    final cases = {
      '2+3×4=': '14',
      '10−4÷2=': '8',
      '0.1+0.2=': '0.3',
      '7÷2=': '3.5',
      '1÷3=': '0.333333333333',
      '50%=': '0.5',
      '9×9×9×9×9×9×9×9×9×9×9×9×9×9×9×9=': '1.85302018885e+15',
      '5+×3=': '15',
      '5+=': '5',
      '.5+1=': '1.5',
    };
    cases.forEach((keys, expected) {
      test('$keys gives $expected', () {
        final c = DecoyCalculator();
        type(c, keys);
        expect(c.display, expected);
      });
    });

    test('shows the sum while typing and after "="', () {
      final c = DecoyCalculator();
      type(c, '12+3');
      expect(c.history, '12 + 3');
      type(c, '=');
      expect(c.history, '12 + 3 =');
      expect(c.display, '15');
    });

    test('carries on from a result, and a digit starts afresh', () {
      final c = DecoyCalculator();
      type(c, '5+5=×2=');
      expect(c.display, '20');
      type(c, '7');
      expect(c.display, '7');
      expect(c.history, '');
    });

    test('backspace, clear and division by zero', () {
      final c = DecoyCalculator();
      type(c, '123⌫');
      expect(c.display, '12');
      type(c, '+⌫⌫');
      expect(c.display, '1');
      type(c, 'C');
      expect(c.display, '0');
      type(c, '8÷0=');
      expect(c.display, "Can't divide by 0");
      type(c, '3');
      expect(c.display, '3');
    });
  });

  group('codes', () {
    test('"112 =" asks for a quick SOS and shows 112 like any number', () {
      final c = DecoyCalculator();
      expect(type(c, '112='), isA<QuickSosEntry>());
      expect(c.display, '112');
    });

    test('a 4–6 digit entry is a PIN attempt, with leading zeros kept', () {
      final c = DecoyCalculator();
      expect((type(c, '0123=') as PinEntry).pin, '0123');
      expect(c.display, '123');
      expect((type(DecoyCalculator(), '1121=') as PinEntry).pin, '1121');
      expect((type(DecoyCalculator(), '258046=') as PinEntry).pin, '258046');
      expect((type(DecoyCalculator(), '125⌫80=') as PinEntry).pin, '1280');
    });

    test('ordinary sums never trigger anything', () {
      for (final keys in ['112+0=', '100+12=', '123=', '1234567=', '12.34=', '1120÷10=', '112%=', '1234+=']) {
        expect(type(DecoyCalculator(), keys), isNull, reason: keys);
      }
      final c = DecoyCalculator();
      type(c, '112=');
      expect(type(c, '='), isNull, reason: 'pressing = again repeats nothing');
      type(c, '+0');
      expect(type(c, '='), isNull);
    });
  });
}
