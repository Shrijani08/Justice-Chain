/// A code typed on the disguise calculator and confirmed with "=".
sealed class SecretEntry {
  const SecretEntry();
}

/// "112 =": start an SOS recording without unlocking.
class QuickSosEntry extends SecretEntry {
  const QuickSosEntry();
}

/// A 4–6 digit number then "=": possibly the vault PIN.
class PinEntry extends SecretEntry {
  const PinEntry(this.pin);
  final String pin;
}

/// The disguise mode's calculator: a real, working four-function calculator
/// (× and ÷ before + and −, as phone calculators do), which also reports the
/// two codes Sakshya listens for. Each code works only as a whole entry on
/// its own, so ordinary sums never trigger anything.
class DecoyCalculator {
  static const quickSosCode = '112';
  static const operators = {'+', '−', '×', '÷'};
  static const _maxDigits = 15;

  final List<String> _parts = []; // number, operator, number, operator…
  String _entry = '0';
  String _typed = ''; // digit keys pressed for this entry, leading zeros kept
  String _history = '';
  bool _showingResult = false;

  /// The main line: what is being typed, or the last result.
  String get display => _entry;

  /// The small line above it: the sum so far, or the last sum and "=".
  String get history => _showingResult ? _history : [..._parts, if (_parts.isNotEmpty && _typed.isNotEmpty) _entry].join(' ');

  /// Presses one key: a digit, '.', an operator, '%', 'C', '⌫' or '='.
  /// Returns a [SecretEntry] when '=' completes one of the codes.
  SecretEntry? press(String key) {
    if (RegExp(r'^\d$').hasMatch(key)) {
      _digit(key);
    } else if (key == '.') {
      _point();
    } else if (operators.contains(key)) {
      _operator(key);
    } else if (key == '%') {
      _entry = _format(_value(_entry) / 100);
      _typed = '';
    } else if (key == 'C') {
      _clear();
    } else if (key == '⌫') {
      _backspace();
    } else if (key == '=') {
      return _equals();
    } else {
      throw ArgumentError.value(key, 'key', 'not a calculator key');
    }
    return null;
  }

  void _digit(String d) {
    if (_showingResult) _clear();
    if (_typed.replaceAll('.', '').length >= _maxDigits) return;
    _typed += d;
    _entry = (_entry == '0' || _typed.length == 1) ? d : _entry + d;
  }

  void _point() {
    if (_showingResult) _clear();
    if (_entry.contains('.') && _typed.isNotEmpty) return;
    _entry = _typed.isEmpty ? '0.' : '$_entry.';
    _typed += '.';
  }

  void _operator(String op) {
    if (_entry == "Can't divide by 0") return;
    _showingResult = false;
    if (_typed.isEmpty && _parts.isNotEmpty && operators.contains(_parts.last)) {
      _parts[_parts.length - 1] = op; // changed their mind about the operator
      return;
    }
    _parts
      ..add(_entry)
      ..add(op);
    _typed = '';
  }

  void _backspace() {
    if (_showingResult) return;
    if (_typed.isNotEmpty) {
      _typed = _typed.substring(0, _typed.length - 1);
      _entry = _typed.isEmpty ? '0' : (_typed.startsWith('.') ? '0$_typed' : _typed.replaceFirst(RegExp(r'^0+(?=\d)'), ''));
    } else if (_parts.isNotEmpty) {
      _parts.removeLast(); // the operator
      _entry = _parts.removeLast();
      _typed = _entry;
    }
  }

  void _clear() {
    _parts.clear();
    _entry = '0';
    _typed = '';
    _history = '';
    _showingResult = false;
  }

  SecretEntry? _equals() {
    if (_showingResult) return null;
    // A code is a whole entry on its own: digits only, no sum around it.
    SecretEntry? secret;
    if (_parts.isEmpty && RegExp(r'^\d+$').hasMatch(_typed)) {
      if (_typed == quickSosCode) {
        secret = const QuickSosEntry();
      } else if (_typed.length >= 4 && _typed.length <= 6) {
        secret = PinEntry(_typed);
      }
    }
    final terms = [..._parts, if (_typed.isNotEmpty || _parts.isEmpty) _entry];
    if (operators.contains(terms.last)) terms.removeLast();
    final result = _evaluate(terms);
    _history = '${terms.join(' ')} =';
    _parts.clear();
    _typed = '';
    _entry = result == null ? "Can't divide by 0" : _format(result);
    if (result == null) _history = '';
    _showingResult = true;
    return secret;
  }

  /// Left to right, × and ÷ first. Null on division by zero.
  static double? _evaluate(List<String> terms) {
    final sums = <double>[_value(terms.first)];
    final signs = <String>[];
    for (var i = 1; i < terms.length; i += 2) {
      final op = terms[i];
      final n = _value(terms[i + 1]);
      if (op == '×') {
        sums.last *= n;
      } else if (op == '÷') {
        if (n == 0) return null;
        sums.last /= n;
      } else {
        signs.add(op);
        sums.add(n);
      }
    }
    var total = sums.first;
    for (var i = 0; i < signs.length; i++) {
      total = signs[i] == '+' ? total + sums[i + 1] : total - sums[i + 1];
    }
    return total;
  }

  static double _value(String s) => double.tryParse(s) ?? 0;

  /// Up to 12 significant digits, without trailing zeros (0.1 + 0.2 shows 0.3).
  static String _format(double v) {
    if (v.isNaN || v.isInfinite) return 'Error';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    var s = v.toStringAsPrecision(12);
    if (s.contains('e')) {
      final [mantissa, exponent] = s.split('e');
      return '${_trimZeros(mantissa)}e$exponent';
    }
    return _trimZeros(s);
  }

  static String _trimZeros(String s) =>
      s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}
