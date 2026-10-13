import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic/decoy_calculator.dart';

/// The disguise mode's face: a plain, working calculator. It never shows
/// anything about Sakshya; the codes it recognises are handled by the
/// callbacks, and the display behaves exactly as for any other number.
class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({
    super.key,
    required this.onPinEntered,
    required this.onQuickSos,
  });

  /// A 4–6 digit entry confirmed with "=" (maybe the vault PIN).
  final ValueChanged<String> onPinEntered;

  /// "112 =".
  final VoidCallback onQuickSos;

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  final _calculator = DecoyCalculator();

  static const _rows = [
    ['C', '⌫', '%', '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '−'],
    ['1', '2', '3', '+'],
    ['0', '.', '='],
  ];

  void _press(String key) {
    final secret = _calculator.press(key);
    setState(() {});
    switch (secret) {
      case QuickSosEntry():
        widget.onQuickSos();
      case PinEntry(:final pin):
        widget.onPinEntered(pin);
      case null:
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blueGrey,
        brightness: Brightness.dark,
      ),
    );
    return Theme(
      data: theme,
      // Light status-bar icons on the dark calculator.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF16181A),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _calculator.history,
                          key: const ValueKey('calc-history'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            color: Color(0xFF9AA0A6),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            _calculator.display,
                            key: const ValueKey('calc-display'),
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 64,
                              color: Colors.white,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: Column(
                    children: [
                      for (final row in _rows)
                        Row(
                          children: [
                            for (final key in row)
                              Expanded(
                                flex: key == '0' ? 2 : 1,
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: _Key(
                                    label: key,
                                    onTap: () => _press(key),
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isOperator =
        DecoyCalculator.operators.contains(label) || label == '=';
    final isFunction = label == 'C' || label == '⌫' || label == '%';
    final background = isOperator
        ? const Color(0xFF5F7A8A)
        : isFunction
        ? const Color(0xFF3A3F44)
        : const Color(0xFF26292C);
    return SizedBox(
      height: 68,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(34),
        child: InkWell(
          key: ValueKey('calc-$label'),
          borderRadius: BorderRadius.circular(34),
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: const TextStyle(fontSize: 28, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
