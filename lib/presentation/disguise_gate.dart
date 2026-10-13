import 'package:flutter/material.dart';

import '../core/disguise_service.dart';
import '../logic/safety_signals.dart';
import 'calculator_screen.dart';

/// Covers the whole app with the calculator while disguise mode is on. It
/// sits above the navigator (MaterialApp.builder), so it also covers any
/// screen that was open, and locks again whenever the app goes to the
/// background. The app underneath keeps running while covered (AI
/// monitoring, the camera, the outbox), so "112 =" can record at once.
class DisguiseGate extends StatefulWidget {
  const DisguiseGate({super.key, required this.child});
  final Widget child;

  @override
  State<DisguiseGate> createState() => _DisguiseGateState();
}

class _DisguiseGateState extends State<DisguiseGate> with WidgetsBindingObserver {
  late bool _locked = DisguiseService.enabled.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && DisguiseService.enabled.value && !_locked) {
      setState(() => _locked = true);
    }
  }

  Future<void> _tryPin(String pin) async {
    if (await DisguiseService.unlock(pin) && mounted) {
      setState(() => _locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Offstage(
          offstage: _locked,
          child: TickerMode(enabled: !_locked, child: widget.child),
        ),
        if (_locked)
          CalculatorScreen(
            onPinEntered: _tryPin,
            onQuickSos: () => sosRequested.value = true,
          ),
      ],
    );
  }
}
