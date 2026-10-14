import 'package:flutter/material.dart';

import '../core/identity_service.dart';

/// Shows the recovery code once, right after registration, and asks the
/// user to type its last group back to prove they wrote it down. After
/// that the phone forgets it.
class RecoveryCodeScreen extends StatefulWidget {
  const RecoveryCodeScreen({super.key, required this.onDone});

  /// Called once the code is confirmed, or straight away on a phone that
  /// has no recovery code (set up before recovery codes existed).
  final VoidCallback onDone;

  @override
  State<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends State<RecoveryCodeScreen> {
  final _confirmController = TextEditingController();
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    IdentityService.pendingRecoveryCode().then((code) {
      if (!mounted) return;
      if (code == null) {
        widget.onDone();
      } else {
        setState(() => _code = code);
      }
    });
  }

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final lastGroup = _code!.split('-').last;
    if (_confirmController.text.trim().toUpperCase() != lastGroup) {
      setState(() => _error = 'That is not the last group. Check what you wrote down.');
      return;
    }
    await IdentityService.confirmRecoveryCodeSaved();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: code == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text(
                    'Your recovery code',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'If you lose this phone, this code brings back your identity and lets you watch '
                    'your recordings on a new phone, even with no guardians.\n\n'
                    'Write it on paper and keep it somewhere safe. Anyone who has it can open your '
                    'recordings. It is shown only once.',
                    style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      code.split('-').join('  '),
                      key: const ValueKey('recovery-code'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 22,
                        letterSpacing: 2,
                        height: 1.6,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _confirmController,
                    key: const ValueKey('recovery-confirm'),
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(color: Colors.white, letterSpacing: 2),
                    decoration: InputDecoration(
                      labelText: 'Type the last group to confirm',
                      errorText: _error,
                      filled: true,
                      fillColor: Colors.white10,
                    ),
                    onSubmitted: (_) => _confirm(),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text("I'VE WRITTEN IT DOWN"),
                  ),
                ],
              ),
      ),
    );
  }
}
