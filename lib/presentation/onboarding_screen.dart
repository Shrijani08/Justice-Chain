import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design/components.dart';
import 'design/sentinel.dart';
import 'design/tokens.dart';
import 'registration_screen.dart';

/// First run: seven short pages on what Sakshya does, then setup.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _index = 0;
  static const _count = 7;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (SakMotion.reduced(context)) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(page, duration: const Duration(milliseconds: 420), curve: SakMotion.enter);
    }
  }

  void _start() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegistrationScreen()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.home,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const EmberBackground(
            color: Ember.home,
            glows: [
              Glow(color: Ember.deepWine, width: 420, height: 400, left: -40, top: 80),
              Glow(color: Ember.nightPlum, width: 300, height: 260, right: -120, bottom: 60),
            ],
          ),
          SafeArea(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _index = i),
              children: [
                _IntroPage(
                  index: 0,
                  top: const _BrandLabel(),
                  art: const _LogoArt(),
                  title: 'Your silent\nwitness.',
                  body: 'It listens for danger and records proof.',
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(1),
                ),
                _IntroPage(
                  index: 1,
                  art: const _ListenArt(),
                  title: 'It listens\nfor you.',
                  body: 'Hears a scream? It starts recording by itself.',
                  onBack: () => _go(0),
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(2),
                ),
                _IntroPage(
                  index: 2,
                  art: const _SosArt(),
                  title: 'Or tap SOS.',
                  body: 'One tap starts recording, even if the AI misses it.',
                  onBack: () => _go(1),
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(3),
                ),
                _IntroPage(
                  index: 3,
                  art: const _SealArt(),
                  title: 'Proof is\nsealed.',
                  body: 'Each clip is locked and stamped. No one can change it.',
                  onBack: () => _go(2),
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(4),
                ),
                _IntroPage(
                  index: 4,
                  art: const _GuardiansArt(),
                  title: 'Guardians\nhold the key.',
                  body: 'Two people you trust must agree to open a clip.',
                  onBack: () => _go(3),
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(5),
                ),
                _IntroPage(
                  index: 5,
                  art: const _CalculatorArt(),
                  title: 'Hide it in\nplain sight.',
                  bodySpan: const TextSpan(
                    children: [
                      TextSpan(text: 'It can look like a calculator. Type '),
                      TextSpan(text: '112 =', style: TextStyle(fontWeight: FontWeight.w700, color: Ember.ink)),
                      TextSpan(text: ' to record.'),
                    ],
                  ),
                  onBack: () => _go(4),
                  onSkip: () => _go(_count - 1),
                  onNext: () => _go(6),
                ),
                _StepsPage(onBack: () => _go(5), onStart: _start),
              ],
            ),
          ),
          // The dots sit above the pages so they glide between them.
          if (_index < _count - 1)
            Positioned(
              left: 28,
              bottom: MediaQuery.paddingOf(context).bottom + 36 + 26,
              child: PageDots(count: _count, index: _index),
            ),
        ],
      ),
    );
  }
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({
    required this.index,
    required this.art,
    required this.title,
    this.body,
    this.bodySpan,
    this.top,
    this.onBack,
    required this.onSkip,
    required this.onNext,
  });

  final int index;
  final Widget art;
  final String title;
  final String? body;
  final TextSpan? bodySpan;
  final Widget? top;
  final VoidCallback? onBack;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final bodyStyle = context.type.bodyLarge?.copyWith(fontSize: 21, height: 29 / 21, color: const Color(0xC7F4ECEE));
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (top != null)
                top!
              else if (onBack != null)
                Semantics(
                  button: true,
                  label: 'Back',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onBack,
                    child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(Icons.chevron_left_rounded, size: 28, color: Color(0xB3F4ECEE)),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              _SkipButton(onTap: onSkip),
            ],
          ),
          // Short phones shrink the picture, never the words.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: art)),
            ),
          ),
          _FadeUp(child: Text(title, style: context.type.displayLarge)),
          const SizedBox(height: 16),
          _FadeUp(
            delay: 100,
            child: bodySpan != null ? Text.rich(bodySpan!, style: bodyStyle) : Text(body!, style: bodyStyle),
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [_NextPill(onTap: onNext)],
          ),
        ],
      ),
    );
  }
}

class _BrandLabel extends StatelessWidget {
  const _BrandLabel();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text('Sakshya', style: context.type.titleMedium?.copyWith(letterSpacing: -0.2)),
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 0, 10),
          child: Text('Skip', style: context.type.titleMedium?.copyWith(color: const Color(0xB3F4ECEE))),
        ),
      ),
    );
  }
}

class _NextPill extends StatelessWidget {
  const _NextPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Next',
      child: Pressable(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 30),
            decoration: BoxDecoration(gradient: Ember.pearlSoftGradient, borderRadius: BorderRadius.circular(SakRadius.pill)),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Next', style: TextStyle(fontFamily: SakFont.body, fontSize: 18, fontWeight: FontWeight.w700, color: Ember.onPearl)),
                SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 22, color: Ember.onPearl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The canvas's "in" entrance: up 14 px and fade, 600 ms.
class _FadeUp extends StatelessWidget {
  const _FadeUp({required this.child, this.delay = 0});
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    if (SakMotion.reduced(context)) return child;
    final total = 600 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: SakMotion.enter),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// A repeating 0–1 clock for the small illustrations.
class _Loop extends StatefulWidget {
  const _Loop({required this.period, required this.builder});
  final Duration period;
  final Widget Function(BuildContext context, double t) builder;

  @override
  State<_Loop> createState() => _LoopState();
}

class _LoopState extends State<_Loop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SakMotion.reduced(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _c, builder: (context, _) => widget.builder(context, _c.value));
}

class _LogoArt extends StatelessWidget {
  const _LogoArt();

  @override
  Widget build(BuildContext context) {
    return _FadeUp(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: const BoxDecoration(
              boxShadow: [BoxShadow(color: Color(0x8C8A2E46), blurRadius: 44, offset: Offset(0, 18))],
              borderRadius: BorderRadius.all(Radius.circular(36)),
            ),
            child: Image.asset('assets/images/sakshya_logo.png', width: 156, height: 151, semanticLabel: 'Sakshya logo'),
          ),
          const SizedBox(height: 26),
          const Padding(
            padding: EdgeInsets.only(left: 11),
            child: Text(
              'SAKSHYA',
              style: TextStyle(fontFamily: SakFont.body, fontSize: 30, fontWeight: FontWeight.w400, letterSpacing: 11, color: Ember.ink),
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.only(left: 3.6),
            child: Text(
              "PROOF THAT CAN'T BE ERASED",
              style: TextStyle(fontFamily: SakFont.body, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 3.6, color: Ember.rose),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListenArt extends StatelessWidget {
  const _ListenArt();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 112,
            height: 112,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Ember.glass,
              border: Border.fromBorderSide(BorderSide(color: Ember.glassBorder)),
              boxShadow: [BoxShadow(color: Color(0x995A0F22), blurRadius: 60)],
            ),
            child: const Icon(Icons.mic_none_rounded, size: 48, color: Ember.blush),
          ),
          const SizedBox(height: 26),
          const WaveBars(
            heights: [24, 46, 70, 40, 84, 58, 90, 62, 44, 76, 52, 30],
            barWidth: 5,
            gap: 5,
          ),
        ],
      ),
    );
  }
}

class _SosArt extends StatelessWidget {
  const _SosArt();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 300,
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Ember.emberStart, Ember.emberEnd], stops: [0, 0.75]),
          borderRadius: BorderRadius.circular(SakRadius.pill),
          border: Border.all(color: Ember.emberEdge),
          boxShadow: const [BoxShadow(color: Color(0x995A0F22), blurRadius: 50, offset: Offset(0, 20))],
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x1FFFFFFF)),
                  child: const Icon(Icons.videocam_outlined, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text('SOS · Record', style: TextStyle(fontFamily: SakFont.body, fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 26,
              top: 12,
              child: _Loop(
                period: const Duration(seconds: 2),
                builder: (context, t) {
                  final p = (t / 0.7).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: 0.9 * (1 - p),
                    child: Transform.scale(
                      scale: 0.6 + p,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0x99F4ECEE), width: 2),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SealArt extends StatelessWidget {
  const _SealArt();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: SakMotion.reduced(context) ? 1 : 0, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: SakMotion.enter,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 1.35 - 0.35 * t, child: child),
            ),
            child: const SealDisc(size: 150, icon: Icons.lock_outline_rounded, iconColor: Ember.blush),
          ),
          const SizedBox(height: 22),
          const Glass(
            radius: 12,
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: MonoText('9f3a 7c21 e0b4 …', style: TextStyle(fontSize: 15, letterSpacing: 1, color: Color(0xCCF4ECEE))),
          ),
        ],
      ),
    );
  }
}

/// A dark disc with a dashed inner ring: the seal on onboarding and the
/// Sealed screen.
class SealDisc extends StatelessWidget {
  const SealDisc({super.key, required this.size, required this.icon, required this.iconColor});
  final double size;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFF3A1520), Color(0xFF14070B)]),
        border: Border.all(color: const Color(0x24FFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0x08FFFFFF), spreadRadius: 12),
          BoxShadow(color: Color(0x995A0F22), blurRadius: 70, offset: Offset(0, 30)),
        ],
      ),
      child: Center(
        child: CustomPaint(
          painter: _DashedRing(),
          child: SizedBox.square(
            dimension: size * 0.73,
            child: Icon(icon, size: size * 0.33, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _DashedRing extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x80D99AAB);
    final r = size.width / 2;
    const dashes = 40;
    for (var i = 0; i < dashes; i++) {
      final a = i * 2 * math.pi / dashes;
      canvas.drawArc(Rect.fromCircle(center: size.center(Offset.zero), radius: r), a, math.pi / dashes, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => false;
}

class _GuardiansArt extends StatelessWidget {
  const _GuardiansArt();

  @override
  Widget build(BuildContext context) {
    Widget key(double from, double t) {
      final p = ((t - 0.15) / 0.4).clamp(0.0, 1.0);
      final eased = SakMotion.enter.transform(p);
      return Transform.translate(
        offset: Offset(from * (1 - eased), 0),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Ember.glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Ember.glassBorder),
          ),
          child: const Icon(Icons.key_rounded, size: 22, color: Ember.blush),
        ),
      );
    }

    return ExcludeSemantics(
      child: _Loop(
        period: const Duration(milliseconds: 2400),
        builder: (context, t) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(mainAxisSize: MainAxisSize.min, children: [
              const _BigAvatar('M', [Color(0xFF7A2E40), Color(0xFF3A1320)]),
              const SizedBox(height: 12),
              key(-26, t),
            ]),
            const SizedBox(width: 18),
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: const RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFF3A1520), Color(0xFF14070B)]),
                border: Border.all(color: const Color(0x24FFFFFF)),
                boxShadow: const [BoxShadow(color: Color(0x995A0F22), blurRadius: 60, offset: Offset(0, 24))],
              ),
              child: const Icon(Icons.lock_outline_rounded, size: 40, color: Ember.ink),
            ),
            const SizedBox(width: 18),
            Column(mainAxisSize: MainAxisSize.min, children: [
              const _BigAvatar('R', [Color(0xFF4E2A5E), Color(0xFF24132E)]),
              const SizedBox(height: 12),
              key(26, t),
            ]),
          ],
        ),
      ),
    );
  }
}

class _BigAvatar extends StatelessWidget {
  const _BigAvatar(this.letter, this.colors);
  final String letter;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
      child: Text(letter, style: const TextStyle(fontFamily: SakFont.display, fontSize: 30, fontWeight: FontWeight.w700, color: Ember.ink)),
    );
  }
}

class _CalculatorArt extends StatelessWidget {
  const _CalculatorArt();

  @override
  Widget build(BuildContext context) {
    Widget k(String label, {bool op = false, bool hi = false}) => Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: op ? const Color(0xFF5F7A8A) : const Color(0xFF26292C),
            borderRadius: BorderRadius.circular(20),
            border: hi ? Border.all(color: Ember.blush, width: 2) : null,
          ),
          child: Text(label, style: const TextStyle(fontFamily: SakFont.body, fontSize: 17, color: Colors.white)),
        );
    const rows = [
      ['7', '8', '9', '×'],
      ['4', '5', '6', '−'],
      ['1', '2', '3', '+'],
      ['0', '.', '%', '='],
    ];
    return ExcludeSemantics(
      child: Transform.rotate(
        angle: -4 * math.pi / 180,
        child: Container(
          width: 210,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          decoration: BoxDecoration(
            color: const Color(0xFF16181A),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0x1AFFFFFF)),
            boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 70, offset: Offset(0, 30))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(6, 6, 6, 4),
                child: Text('112', textAlign: TextAlign.right, style: TextStyle(fontFamily: SakFont.body, fontSize: 38, fontWeight: FontWeight.w300, color: Colors.white)),
              ),
              for (final row in rows) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(child: k(row[i], op: i == 3, hi: row[i] == '1' || row[i] == '=')),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StepsPage extends StatelessWidget {
  const _StepsPage({required this.onBack, required this.onStart});
  final VoidCallback onBack;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('Create your identity', 'Your name and a PIN'),
      ('Save your recovery code', 'Write it on paper'),
      ('Let it run in background', 'Permissions, notification, battery'),
      ('Add 2 guardians', 'Scan their QR code'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 36),
      child: FillScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                button: true,
                label: 'Back',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBack,
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(Icons.chevron_left_rounded, size: 28, color: Color(0xB3F4ECEE)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            _FadeUp(child: Text('4 quick steps.', style: context.type.displayLarge)),
            const SizedBox(height: 12),
            _FadeUp(
              delay: 80,
              child: Text(
                'About three minutes.',
                style: context.type.bodyLarge?.copyWith(fontSize: 21, height: 29 / 21, color: const Color(0xC7F4ECEE)),
              ),
            ),
            const SizedBox(height: 28),
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _FadeUp(
                delay: 120 + i * 100,
                child: Glass(
                  radius: SakRadius.card,
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      StepNumber(i + 1, size: 48),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(steps[i].$1, style: context.type.titleLarge),
                            const SizedBox(height: 4),
                            Text(steps[i].$2, style: context.type.bodyLarge?.copyWith(color: const Color(0xB3F4ECEE))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const Spacer(),
            const SizedBox(height: 28),
            const Center(child: PageDots(count: 7, index: 6)),
            const SizedBox(height: 22),
            SakButton(label: 'Get started', height: 62, fontSize: 19, onPressed: onStart),
          ],
        ),
      ),
    );
  }
}
