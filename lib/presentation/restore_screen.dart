import 'package:flutter/material.dart';

import '../core/recovery_service.dart';
import 'home_screen.dart';

/// "Restore with recovery code": brings back a lost phone's identity and
/// lists its recordings from the ledger, so they can be watched again.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  bool _working = false;
  String? _codeError;

  @override
  void dispose() {
    for (final c in [_codeController, _nameController, _pinController, _confirmPinController]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() => _codeError = null);
    if (!_formKey.currentState!.validate()) return;
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
            'Pair your guardians again from "Scan QR".'),
      ));
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainSafetyScreen()),
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

  InputDecoration _decoration(String label, {String? error}) => InputDecoration(
        labelText: label,
        errorText: error,
        filled: true,
        fillColor: Colors.white10,
        counterText: '',
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Restore with recovery code'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Enter the code you wrote down when you first set up the app. '
              'This phone becomes your old phone: same identity, and your recordings come back from the ledger.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _codeController,
              key: const ValueKey('restore-code'),
              textCapitalization: TextCapitalization.characters,
              minLines: 2,
              maxLines: 2,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', letterSpacing: 1.5),
              decoration: _decoration('Recovery code', error: _codeError),
              validator: (v) => v == null || v.trim().isEmpty ? 'Enter your recovery code' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameController,
              key: const ValueKey('restore-name'),
              style: const TextStyle(color: Colors.white),
              decoration: _decoration('Your name'),
              validator: (v) => v == null || v.trim().isEmpty ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pinController,
              key: const ValueKey('restore-pin'),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              style: const TextStyle(color: Colors.white, letterSpacing: 4),
              decoration: _decoration('New vault PIN (4-6 digits)'),
              validator: (v) => v == null || !RegExp(r'^\d{4,6}$').hasMatch(v) ? 'PIN must be 4-6 digits' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmPinController,
              key: const ValueKey('restore-confirm-pin'),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              style: const TextStyle(color: Colors.white, letterSpacing: 4),
              decoration: _decoration('Confirm PIN'),
              validator: (v) => v != _pinController.text ? 'PINs do not match' : null,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              key: const ValueKey('restore-button'),
              onPressed: _working ? null : _restore,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.tealAccent.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _working
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('RESTORE'),
            ),
          ],
        ),
      ),
    );
  }
}
