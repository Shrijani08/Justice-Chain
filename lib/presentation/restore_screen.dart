import 'package:flutter/material.dart';

import '../core/recovery_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';
import 'registration_screen.dart' show PinBoxes;
import 'setup_screens.dart';

/// "Restore with recovery code": brings back a lost phone's identity and
/// lists its recordings from the ledger, so they can be watched again.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _working = false;
  String? _codeError;
  String? _nameError;
  String? _pinError;
  String? _confirmError;

  @override
  void dispose() {
    for (final c in [_codeController, _nameController, _pinController, _confirmPinController]) {
      c.dispose();
    }
    _pinFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _codeError = _codeController.text.trim().isEmpty ? 'Enter your recovery code' : null;
      _nameError = _nameController.text.trim().isEmpty ? 'Name is required' : null;
      _pinError = RegExp(r'^\d{4,6}$').hasMatch(_pinController.text) ? null : 'PIN must be 4-6 digits';
      _confirmError = _confirmPinController.text != _pinController.text ? 'PINs do not match' : null;
    });
    return _codeError == null && _nameError == null && _pinError == null && _confirmError == null;
  }

  Future<void> _restore() async {
    if (!_validate()) return;
    setState(() => _working = true);
    try {
      final found = await RecoveryService.restore(
        code: _codeController.text,
        name: _nameController.text.trim(),
        pin: _pinController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Identity restored. $found recording${found == 1 ? '' : 's'} found on the ledger. '
            'Pair your guardians again.'),
      ));
      // A new phone still needs its permissions and battery set up.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const PermissionsScreen()),
        (_) => false,
      );
    } on FormatException catch (e) {
      setState(() => _codeError = e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF7A1F33), width: 400, height: 340, opacity: 0.85, left: -60, top: -140),
        Glow(color: Ember.plumGlow, width: 260, height: 260, opacity: 0.9, right: -110, bottom: 80),
      ],
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SakTopBar(),
            const SizedBox(height: 18),
            const ScreenTitle(
              'Restore',
              subtitle: 'Enter the code you wrote down when you first set up the app. '
                  'This phone becomes your old phone: same identity, and your recordings come back from the ledger.',
            ),
            const SizedBox(height: 20),
            const FieldLabel('Recovery code'),
            TextField(
              controller: _codeController,
              key: const ValueKey('restore-code'),
              textCapitalization: TextCapitalization.characters,
              minLines: 2,
              maxLines: 2,
              style: const TextStyle(fontFamily: SakMono.family, fontSize: 16, letterSpacing: 1.5, color: Ember.ink),
              decoration: sakField(hint: 'XXXXX-XXXXX-XXXXX-…', error: _codeError),
            ),
            const SizedBox(height: 20),
            const FieldLabel('Your name'),
            TextField(
              controller: _nameController,
              key: const ValueKey('restore-name'),
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              decoration: sakField(hint: 'Your name', error: _nameError),
              onSubmitted: (_) => _pinFocus.requestFocus(),
            ),
            const SizedBox(height: 18),
            const FieldLabel('New vault PIN · 4–6 digits'),
            PinBoxes(
              key: const ValueKey('restore-pin'),
              controller: _pinController,
              focusNode: _pinFocus,
              label: 'New vault PIN',
              error: _pinError,
              onSubmitted: () => _confirmFocus.requestFocus(),
            ),
            const SizedBox(height: 18),
            const FieldLabel('Confirm PIN'),
            PinBoxes(
              key: const ValueKey('restore-confirm-pin'),
              controller: _confirmPinController,
              focusNode: _confirmFocus,
              label: 'Confirm PIN',
              error: _confirmError,
              onSubmitted: () {
                if (!_working) _restore();
              },
            ),
            const Spacer(),
            const SizedBox(height: 24),
            SakButton(
              key: const ValueKey('restore-button'),
              label: 'Restore',
              icon: Icons.restore_rounded,
              loading: _working,
              onPressed: _working ? null : _restore,
            ),
          ],
        ),
      ),
    );
  }
}
