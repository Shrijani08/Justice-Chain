import 'package:flutter/material.dart';

import '../core/identity_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';

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
    final c = context.sak;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: code == null
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(SakSpace.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Reveal(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SakIconTile(icon: Icons.key_rounded, size: 48),
                              const SizedBox(height: SakSpace.lg),
                              Text('Your Recovery Code', style: context.type.headlineMedium),
                              const SizedBox(height: SakSpace.md),
                              Text(
                                'If you lose this phone, this code brings back your identity and lets you watch '
                                'your recordings on a new phone, even with no guardians.',
                                style: context.type.bodyLarge?.copyWith(color: c.inkSecondary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: SakSpace.xl),
                        Reveal(index: 1, child: _CodeSlip(code: code)),
                        const SizedBox(height: SakSpace.lg),
                        const Reveal(
                          index: 2,
                          child: SakNotice(
                            tone: NoticeTone.warning,
                            title: 'Shown only once',
                            message:
                                'Write it on paper and keep it somewhere safe. '
                                'Anyone who has it can open your recordings.',
                          ),
                        ),
                        const SizedBox(height: SakSpace.xl),
                        Reveal(
                          index: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _confirmController,
                                key: const ValueKey('recovery-confirm'),
                                textCapitalization: TextCapitalization.characters,
                                style: context.type.bodyLarge?.copyWith(
                                  fontFamily: SakMono.family,
                                  fontFamilyFallback: SakMono.fallback,
                                  letterSpacing: 2,
                                ),
                                decoration: InputDecoration(
                                  labelText: 'Type the last group to confirm',
                                  errorText: _error,
                                  prefixIcon: const Icon(Icons.edit_note_rounded),
                                ),
                                onChanged: (_) {
                                  if (_error != null) setState(() => _error = null);
                                },
                                onSubmitted: (_) => _confirm(),
                              ),
                              const SizedBox(height: SakSpace.lg),
                              SakButton(label: "I've Written It Down", icon: Icons.check_rounded, onPressed: _confirm),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// The code on a perforated slip, like a custody receipt.
class _CodeSlip extends StatelessWidget {
  const _CodeSlip({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    return Container(
      padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.lg, SakSpace.lg, SakSpace.xl),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(SakRadius.card),
        border: Border.all(color: c.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('RECOVERY CODE', style: context.type.labelSmall?.copyWith(letterSpacing: 1.2)),
              const Spacer(),
              Icon(Icons.lock_rounded, size: 14, color: c.inkTertiary),
            ],
          ),
          const SizedBox(height: SakSpace.md),
          CustomPaint(painter: _Perforation(c.separator), child: const SizedBox(height: 1)),
          const SizedBox(height: SakSpace.lg),
          MonoText(
            code.split('-').join('  '),
            key: const ValueKey('recovery-code'),
            selectable: true,
            textAlign: TextAlign.center,
            style: context.type.titleLarge?.copyWith(letterSpacing: 2, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _Perforation extends CustomPainter {
  _Perforation(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 3, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Perforation old) => old.color != color;
}
