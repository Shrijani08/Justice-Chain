import 'package:flutter/material.dart';

import '../core/identity_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// Setup 2: shows the recovery code once, right after registration, and
/// asks the user to type its last group back to prove they wrote it down.
/// After that the phone forgets it.
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
    // The code is shown only once, so there is no way back to registration.
    return PopScope(
      canPop: false,
      child: EmberScaffold(
        glows: const [
          Glow(color: Ember.deepWine, width: 360, height: 300, right: -140, top: -80),
          Glow(color: Ember.nightPlum, width: 360, height: 320, opacity: 0.85, left: -160, top: 320),
        ],
        child: code == null
            ? const Center(child: CircularProgressIndicator())
            : FillScroll(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0x598E1B32),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0x4DC98597)),
                        ),
                        child: const Icon(Icons.key_rounded, color: Ember.blush, size: 24),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const ScreenTitle(
                      'Your recovery code',
                      subtitle: 'Lose this phone and this code brings back your identity and recordings, even with no guardians.',
                    ),
                    const SizedBox(height: 16),
                    Reveal(index: 1, child: _CodeSlip(code: code)),
                    const SizedBox(height: 16),
                    const Reveal(
                      index: 2,
                      child: SakNotice(
                        tone: NoticeTone.attention,
                        title: 'Shown only once',
                        message: 'Write it on paper. Anyone who has it can open your recordings.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    const FieldLabel('Type the last group to confirm'),
                    TextField(
                      controller: _confirmController,
                      key: const ValueKey('recovery-confirm'),
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(fontFamily: SakMono.family, fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: 3, color: Ember.ink),
                      decoration: sakField(hint: 'Last 5 characters', error: _error),
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                      onSubmitted: (_) => _confirm(),
                    ),
                    const Spacer(),
                    const SizedBox(height: 24),
                    SakButton(label: "I've written it down", style: SakButtonStyle.pearl, onPressed: _confirm),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The code on a slip: four-character groups in a grid, the last one lit.
class _CodeSlip extends StatelessWidget {
  const _CodeSlip({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final groups = code.split('-');
    return Semantics(
      label: 'Recovery code ${groups.join(' ')}',
      child: Glass(
        radius: SakRadius.card,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Text('RECOVERY CODE', style: TextStyle(fontFamily: SakMono.family, fontSize: 11, letterSpacing: 1.6, color: Color(0x99F4ECEE))),
                Spacer(),
                Icon(Icons.lock_outline_rounded, size: 14, color: Color(0x99F4ECEE)),
              ],
            ),
            const SizedBox(height: 14),
            CustomPaint(painter: _Perforation(), child: const SizedBox(height: 1.5)),
            const SizedBox(height: 14),
            SelectionArea(
              child: Column(
                children: [
                  for (var row = 0; row * 3 < groups.length; row++) ...[
                    if (row > 0) const SizedBox(height: 8),
                    Row(
                      children: [
                        for (var col = 0; col < 3; col++) ...[
                          if (col > 0) const SizedBox(width: 8),
                          Expanded(
                            child: row * 3 + col < groups.length
                                ? _Group(text: groups[row * 3 + col], index: row * 3 + col, last: row * 3 + col == groups.length - 1)
                                : const SizedBox(),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.text, required this.index, required this.last});
  final String text;
  final int index;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: last ? const Color(0x29F2A7B5) : const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        key: ValueKey('recovery-group-$index'),
        style: TextStyle(
          fontFamily: SakMono.family,
          fontSize: 17,
          fontWeight: FontWeight.w500,
          letterSpacing: 2,
          color: last ? Ember.roseSoft : Ember.ink,
        ),
      ),
    );
  }
}

class _Perforation extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x2EFFFFFF)
      ..strokeWidth = 1.5;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Perforation old) => false;
}
