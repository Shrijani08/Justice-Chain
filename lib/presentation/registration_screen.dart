import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/identity_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'recovery_code_screen.dart';
import 'restore_screen.dart';
import 'setup_screens.dart';

/// Setup 1: the user's name and vault PIN. Keys are made on the phone.
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();

  bool _isProcessing = false;
  String? _nameError;
  String? _pinError;
  String? _confirmError;

  @override
  void dispose() {
    _nameController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    _pinFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _nameError = _nameController.text.trim().isEmpty ? 'Enter your name' : null;
      _pinError = _pinController.text.length < 4 ? 'PIN must be at least 4 digits' : null;
      _confirmError = _confirmPinController.text != _pinController.text ? 'PINs do not match' : null;
    });
    return _nameError == null && _pinError == null && _confirmError == null;
  }

  Future<void> _processRegistration() async {
    if (!_validate()) return;
    setState(() => _isProcessing = true);

    try {
      await IdentityService.registerNode(
        name: _nameController.text.trim(),
        pin: _pinController.text.trim(),
      );

      if (mounted) {
        // Show the recovery code once, then background setup. The navigator
        // outlives this screen, which is replaced first.
        final navigator = Navigator.of(context);
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (context) => RecoveryCodeScreen(
              onDone: () => navigator.pushReplacement(
                MaterialPageRoute(builder: (context) => const PermissionsScreen()),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create your identity: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF7A1F33), width: 400, height: 340, opacity: 0.85, left: -60, top: -140),
        Glow(color: Color(0xFF3B1C3F), width: 260, height: 260, opacity: 0.9, right: -110, bottom: 80),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SakTopBar(),
            const SizedBox(height: 18),
            const ScreenTitle(
              'Create your identity',
              subtitle: 'Your keys are made on this phone and kept in its hardware keystore.',
            ),
            const SizedBox(height: 18),
            const FieldLabel('Your name'),
            TextField(
              controller: _nameController,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              decoration: sakField(hint: 'Your name', error: _nameError),
              onSubmitted: (_) => _pinFocus.requestFocus(),
            ),
            const SizedBox(height: 18),
            const FieldLabel('Vault PIN · 4–6 digits'),
            PinBoxes(
              key: const ValueKey('pin'),
              controller: _pinController,
              focusNode: _pinFocus,
              label: 'Vault PIN',
              error: _pinError,
              onSubmitted: () => _confirmFocus.requestFocus(),
            ),
            const SizedBox(height: 18),
            const FieldLabel('Confirm PIN'),
            PinBoxes(
              key: const ValueKey('confirm-pin'),
              controller: _confirmPinController,
              focusNode: _confirmFocus,
              label: 'Confirm PIN',
              error: _confirmError,
              onSubmitted: () {
                if (!_isProcessing) _processRegistration();
              },
            ),
            const SizedBox(height: 18),
            const Glass(
              radius: 18,
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.calculate_outlined, size: 18, color: Ember.rose),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'If you turn on the calculator disguise, this PIN followed by = opens the app.',
                      style: TextStyle(fontFamily: SakFont.body, fontSize: 13, height: 18 / 13, color: Color(0xC7F4ECEE)),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            const SizedBox(height: 24),
            SakButton(
              label: 'Generate secure keys',
              icon: Icons.key_rounded,
              loading: _isProcessing,
              onPressed: _isProcessing ? null : _processRegistration,
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _isProcessing
                  ? null
                  : () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RestoreScreen())),
              child: const Text('Lost your phone? Restore with recovery code', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

/// A PIN typed into six boxes. A hidden field holds the digits; the boxes
/// show one dot per digit and ring the next one.
class PinBoxes extends StatefulWidget {
  const PinBoxes({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    this.error,
    this.onSubmitted,
    this.length = 6,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final String? error;
  final VoidCallback? onSubmitted;
  final int length;

  @override
  State<PinBoxes> createState() => _PinBoxesState();
}

class _PinBoxesState extends State<PinBoxes> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final n = widget.controller.text.length;
    final focused = widget.focusNode.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: '${widget.label}, $n of ${widget.length} digits entered',
          textField: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.focusNode.requestFocus();
              SystemChannels.textInput.invokeMethod('TextInput.show');
            },
            child: Stack(
              children: [
                // The real field, invisible but focusable and typeable.
                Opacity(
                  opacity: 0,
                  child: SizedBox(
                    height: 54,
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: widget.length,
                      obscureText: true,
                      enableInteractiveSelection: false,
                      showCursor: false,
                      decoration: const InputDecoration(counterText: '', border: InputBorder.none, filled: false),
                      onSubmitted: (_) => widget.onSubmitted?.call(),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < widget.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: AnimatedContainer(
                          duration: SakMotion.of(context, SakMotion.quick),
                          height: 54,
                          decoration: BoxDecoration(
                            color: Ember.glass,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: widget.error != null
                                  ? Ember.alertText
                                  : focused && i == n
                                      ? Ember.rose
                                      : const Color(0x24FFFFFF),
                            ),
                            boxShadow: focused && i == n
                                ? const [BoxShadow(color: Color(0x33F2A7B5), spreadRadius: 3)]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: AnimatedScale(
                            scale: i < n ? 1 : 0,
                            duration: SakMotion.of(context, SakMotion.quick),
                            curve: SakMotion.spring,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(color: Ember.ink, shape: BoxShape.circle),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(widget.error!, style: context.type.bodySmall?.copyWith(color: Ember.alertText)),
          ),
      ],
    );
  }
}
