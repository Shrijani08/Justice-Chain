import 'dart:async';

import 'package:flutter/material.dart';

import '../core/evidence_lock.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'registration_screen.dart' show PinBoxes;

/// Shows [child] only after the vault PIN (EvidenceLock). Wraps the screens
/// that list recordings, so every way into them asks first; leaving the app
/// locks them again.
class PinGate extends StatefulWidget {
  const PinGate({super.key, required this.child});
  final Widget child;

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> with WidgetsBindingObserver {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  late bool _open = EvidenceLock.isUnlocked;
  bool? _hasPin; // null until read; phones without a PIN are never locked
  bool _busy = false;
  String? _error;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EvidenceLock.hasPin().then((hasPin) {
      if (mounted) setState(() => _hasPin = hasPin);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waitTimer?.cancel();
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      EvidenceLock.lock();
      if (_open) setState(() => _open = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _pin.text.length < 4) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await EvidenceLock.unlock(_pin.text);
    if (!mounted) return;
    _pin.clear();
    final wait = EvidenceLock.waitBeforeNextTry;
    setState(() {
      _busy = false;
      _open = ok;
      _error = ok
          ? null
          : wait > Duration.zero
              ? 'Too many wrong PINs. Try again in ${wait.inSeconds} s.'
              : 'Wrong PIN';
    });
    if (wait > Duration.zero) {
      _waitTimer?.cancel();
      _waitTimer = Timer(wait, () {
        if (mounted) setState(() => _error = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasPin == false || _open) return widget.child;
    if (_hasPin == null) return const EmberScaffold(child: SizedBox.shrink());
    return EmberScaffold(
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SakTopBar(),
            const SizedBox(height: 18),
            const ScreenTitle(
              'Enter your PIN',
              subtitle: 'Your recordings stay locked to anyone else holding this phone. Recording still works without it.',
            ),
            const SizedBox(height: 24),
            const FieldLabel('Vault PIN'),
            PinBoxes(
              key: const ValueKey('evidence-pin'),
              controller: _pin,
              focusNode: _focus,
              label: 'Vault PIN',
              error: _error,
              onSubmitted: _submit,
            ),
            const Spacer(),
            const SizedBox(height: 24),
            SakButton(
              label: 'Unlock',
              icon: Icons.lock_open_rounded,
              loading: _busy,
              onPressed: _busy ? null : _submit,
            ),
            const SizedBox(height: SakSpace.md),
          ],
        ),
      ),
    );
  }
}
