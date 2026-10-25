import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'tokens.dart';

/// Drives a painter from elapsed time, so several loops of different
/// lengths can share one ticker. Stops with reduced motion.
mixin _Clock<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final Ticker _ticker = createTicker((elapsed) => seconds.value = elapsed.inMicroseconds / 1e6);
  final ValueNotifier<double> seconds = ValueNotifier(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = SakMotion.reduced(context) || !TickerMode.valuesOf(context).enabled;
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    seconds.dispose();
    super.dispose();
  }
}

/// The sentinel orb: a round glass shell holding slow wine waves, with a
/// breathing halo. [level] (0–1, the AI's distress score) lifts the waves.
class SakOrb extends StatefulWidget {
  const SakOrb({super.key, this.size = 240, this.level = 0, this.semanticLabel = 'Listening orb'});

  final double size;
  final double level;
  final String semanticLabel;

  @override
  State<SakOrb> createState() => _SakOrbState();
}

class _SakOrbState extends State<SakOrb> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.level.clamp(0, 1)),
            duration: const Duration(milliseconds: 400),
            builder: (context, level, _) => CustomPaint(
              painter: _OrbPainter(seconds, level),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wave {
  const _Wave(this.x0, this.y, this.amp, this.step, this.end, this.dx, this.dur, this.bob, this.paint);

  final double x0, y, amp, step, end;
  final double dx; // travel per loop, in viewBox units
  final double dur; // loop seconds
  final double bob; // vertical bob seconds
  final _WavePaint paint;
}

class _WavePaint {
  const _WavePaint.fill(this.top, this.bottom, this.opacity)
      : stroke = null,
        width = 0;
  const _WavePaint.stroke(Color c, this.width, this.opacity)
      : stroke = c,
        top = null,
        bottom = null;

  final Color? top, bottom, stroke;
  final double opacity, width;
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.seconds, this.level) : super(repaint: seconds);

  final ValueNotifier<double> seconds;
  final double level;

  // The canvas's Orb.dc.html, wave for wave.
  static const _waves = [
    _Wave(-240, 70, 6, 60, 480, -120, 10, 7, _WavePaint.fill(Color(0xFF4A0F1E), Color(0xFF22070F), 0.75)),
    _Wave(-180, 92, 8, 45, 405, 90, 7, 5.5, _WavePaint.fill(Color(0xFF7A1F38), Color(0xFF2A0812), 0.7)),
    _Wave(-280, 114, 9, 70, 490, -140, 12, 8, _WavePaint.fill(Color(0xFF9E3A55), Color(0xFF3A0A16), 0.65)),
    _Wave(-200, 136, 7, 50, 400, 100, 8, 6.5, _WavePaint.fill(Color(0xFF6A1A30), Color(0xFF1A050C), 0.8)),
    _Wave(-260, 156, 6, 65, 520, -130, 11, 7.5, _WavePaint.fill(Color(0xFF4A0F1E), Color(0xFF0E0307), 0.85)),
    _Wave(-240, 64, 5, 60, 480, -120, 10, 7, _WavePaint.stroke(Color(0xFFD99AAB), 0.9, 0.45)),
    _Wave(-180, 88, 7, 45, 405, 90, 7, 5.5, _WavePaint.stroke(Color(0xFFEFC6D1), 0.8, 0.4)),
    _Wave(-280, 110, 8, 70, 490, -140, 12, 8, _WavePaint.stroke(Color(0xFFC98597), 1.1, 0.5)),
    _Wave(-200, 132, 6, 50, 400, 100, 8, 6.5, _WavePaint.stroke(Color(0xFFB85C76), 0.8, 0.45)),
  ];

  Path _wavePath(_Wave w, double amp, {required bool closed}) {
    final p = Path()..moveTo(w.x0, w.y);
    var x = w.x0;
    var sign = -1.0;
    while (x < w.end) {
      p.quadraticBezierTo(x + w.step / 2, w.y + sign * amp, x + w.step, w.y);
      x += w.step;
      sign = -sign;
    }
    if (closed) {
      p
        ..lineTo(x, 215)
        ..lineTo(w.x0, 215)
        ..close();
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = seconds.value;
    canvas.save();
    canvas.scale(size.width / 200, size.height / 200);
    const c = Offset(100, 100);

    // Halo, breathing over 4 s.
    final haloT = 0.6 + 0.4 * (0.5 - 0.5 * math.cos(2 * math.pi * t / 4));
    canvas.drawCircle(
      c,
      118,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(90, 20, 36, 0.55 * haloT * (1 + level * 0.6)),
            const Color.fromRGBO(90, 20, 36, 0),
          ],
          stops: const [0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: 118)),
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: 91)));
    canvas.drawCircle(
      c,
      92,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.6,
          colors: [Color(0xFF2A0812), Color(0xFF0E0307)],
        ).createShader(Rect.fromCircle(center: c, radius: 92)),
    );

    final lift = 1 + level * 1.6;
    for (final w in _waves) {
      final travel = (t % w.dur) / w.dur * w.dx;
      final bob = -3 * (0.5 - 0.5 * math.cos(2 * math.pi * t / w.bob));
      final style = w.paint;
      final path = _wavePath(w, w.amp * lift, closed: style.stroke == null);
      canvas.save();
      canvas.translate(travel, bob - level * 10);
      final paint = Paint()..isAntiAlias = true;
      if (style.stroke != null) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.width
          ..strokeCap = StrokeCap.round
          ..color = style.stroke!.withValues(alpha: style.opacity);
      } else {
        final top = w.y - w.amp * lift;
        paint.shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.top!.withValues(alpha: style.opacity), style.bottom!.withValues(alpha: style.opacity)],
        ).createShader(Rect.fromLTRB(0, top, 10, 215));
      }
      canvas.drawPath(path, paint);
      canvas.restore();
    }
    canvas.restore();

    // The glass shell and its rim light.
    canvas.drawCircle(
      c,
      92,
      Paint()
        ..shader = const RadialGradient(
          colors: [
            Color.fromRGBO(20, 5, 11, 0),
            Color.fromRGBO(34, 7, 15, 0.2),
            Color.fromRGBO(74, 15, 30, 0.65),
            Color.fromRGBO(138, 46, 70, 0.9),
            Color.fromRGBO(201, 133, 151, 0.85),
          ],
          stops: [0, 0.6, 0.84, 0.96, 1],
        ).createShader(Rect.fromCircle(center: c, radius: 92)),
    );

    final highlight = Path()
      ..moveTo(26, 78)
      ..arcToPoint(const Offset(78, 25), radius: const Radius.circular(76));
    canvas.drawPath(
      highlight,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = const Color.fromRGBO(255, 255, 255, 0.28),
    );
    canvas.save();
    canvas.translate(68, 52);
    canvas.rotate(-35 * math.pi / 180);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 60, height: 22),
      Paint()..color = const Color.fromRGBO(255, 255, 255, 0.06),
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.level != level;
}

/// Equaliser bars on the wine gradient. They swing harder as [level] rises.
class WaveBars extends StatefulWidget {
  const WaveBars({super.key, this.heights = _defaultHeights, this.barWidth = 4, this.gap = 4, this.level = 0});

  final List<double> heights;
  final double barWidth;
  final double gap;
  final double level;

  static const _defaultHeights = <double>[
    18.0, 30, 44, 26, 52, 36, 56, 40, 28, 48, 34, 54, 38, 46, 24, 50, 32, 42, 22, 36, 16,
  ];

  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars> with SingleTickerProviderStateMixin, _Clock {
  // The canvas's staggered animation-delays, in seconds.
  static const _delays = [
    0.10, 0.55, 0.20, 0.85, 0.35, 0.70, 0.05, 0.60, 0.25, 0.90, 0.40, 0.15, 0.75, 0.30, 0.65, 0.45, 0.95, 0.12, 0.58, 0.33, 0.80,
  ];

  @override
  Widget build(BuildContext context) {
    final maxH = widget.heights.reduce(math.max);
    return ExcludeSemantics(
      child: SizedBox(
        height: maxH,
        child: ValueListenableBuilder<double>(
          valueListenable: seconds,
          builder: (context, t, _) => Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.heights.length; i++) ...[
                if (i > 0) SizedBox(width: widget.gap),
                Container(
                  width: widget.barWidth,
                  height: widget.heights[i] * _scale(t, i),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.barWidth / 2),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFD99AAB), Color(0xFF8E2A4A), Color(0xFF4A1430)],
                      stops: [0, 0.55, 1],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  double _scale(double t, int i) {
    if (SakMotion.reduced(context)) return 0.6;
    final phase = (t + _delays[i % _delays.length]) / 1.1;
    final swing = 0.5 - 0.5 * math.cos(2 * math.pi * phase);
    final floor = 0.25 + widget.level * 0.25;
    return floor + (1 - floor) * swing;
  }
}

/// Flowing threads of light behind the recording timer.
class RecordingRibbon extends StatefulWidget {
  const RecordingRibbon({super.key, this.height = 220});
  final double height;

  @override
  State<RecordingRibbon> createState() => _RecordingRibbonState();
}

class _RecordingRibbonState extends State<RecordingRibbon> with SingleTickerProviderStateMixin, _Clock {
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(painter: _RibbonPainter(seconds)),
        ),
      ),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter(this.seconds) : super(repaint: seconds);
  final ValueNotifier<double> seconds;

  // (vertical scale, loop seconds, stroke width, opacity, gradient 1 or 2)
  static const _threads = [
    (1.6, 3.0, 1.6, 1.0, 1),
    (1.2, 4.2, 1.4, 1.0, 2),
    (-0.9, 2.4, 1.2, 1.0, 1),
    (0.6, 5.4, 1.0, 1.0, 2),
    (-1.4, 4.2, 0.8, 0.6, 2),
    (0.3, 2.4, 0.8, 0.7, 1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = seconds.value;
    final mid = size.height / 2;
    const period = 195.0;
    final rect = Offset.zero & size;
    final g1 = const LinearGradient(colors: [Color(0x1AF4ECEE), Color(0xFFD99AAB), Color(0x4D8E2A4A)]).createShader(rect);
    final g2 = const LinearGradient(colors: [Color(0x334A1430), Color(0xFFA8455F), Color(0x334A1430)]).createShader(rect);

    for (final (scaleY, dur, width, opacity, grad) in _threads) {
      final shift = (t % dur) / dur * period;
      final path = Path();
      for (double x = 0; x <= size.width; x += 3) {
        final y = mid - 30 * scaleY * math.sin(2 * math.pi * (x + shift) / period);
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..shader = grad == 1 ? g1 : g2
          ..color = Color.fromRGBO(255, 255, 255, opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => false;
}

/// The distress score as a bar with the trigger line drawn in.
class ThresholdMeter extends StatelessWidget {
  const ThresholdMeter({super.key, required this.value, required this.threshold});

  final double value;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return Semantics(
      label: 'Distress score ${(v * 100).round()} percent, trigger at ${(threshold * 100).round()} percent',
      child: ExcludeSemantics(
        child: SizedBox(
          height: 16,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(4)),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: v),
                  duration: SakMotion.of(context, const Duration(milliseconds: 300)),
                  curve: SakMotion.spring,
                  builder: (context, w, _) => Container(
                    width: box.maxWidth * w,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: LinearGradient(
                        colors: v >= threshold
                            ? const [Color(0xFFFF8FA3), Color(0xFFE5484D)]
                            : const [Color(0xFFC98597), Color(0xFF8E2A4A)],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: box.maxWidth * threshold - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: const Color(0xB3FFFFFF)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
