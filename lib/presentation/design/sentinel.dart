import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

enum SentinelState { starting, offline, listening, alert, recording, saving }

/// The home screen's signature: a seal-like disc whose outer ring follows
/// what the AI is hearing right now. It only moves when the level moves.
/// While recording it sends out a ripple once a second and counts time.
class SentinelOrb extends StatefulWidget {
  const SentinelOrb({super.key, required this.state, required this.level, this.size = 220});

  final SentinelState state;

  /// The AI's distress score, 0–1.
  final double level;
  final double size;

  @override
  State<SentinelOrb> createState() => _SentinelOrbState();
}

class _SentinelOrbState extends State<SentinelOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  Timer? _clock;
  DateTime? _recordingSince;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SentinelOrb old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _sync();
  }

  void _sync() {
    final recording = widget.state == SentinelState.recording;
    if (recording && !SakMotion.reduced(context)) {
      if (!_ripple.isAnimating) _ripple.repeat();
    } else {
      _ripple
        ..stop()
        ..value = 0;
    }
    if (recording && _recordingSince == null) {
      _recordingSince = DateTime.now();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!recording) {
      _recordingSince = null;
      _clock?.cancel();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    _clock?.cancel();
    super.dispose();
  }

  String get _elapsed {
    final since = _recordingSince;
    if (since == null) return '00:00';
    final s = DateTime.now().difference(since).inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final (tint, icon, label) = switch (widget.state) {
      SentinelState.starting => (c.inkTertiary, Icons.hourglass_empty_rounded, 'Starting'),
      SentinelState.offline => (c.warning, Icons.mic_off_rounded, 'Not listening'),
      SentinelState.listening => (c.accent, Icons.graphic_eq_rounded, 'Listening'),
      SentinelState.alert => (c.danger, Icons.hearing_rounded, 'Distress heard'),
      SentinelState.recording => (c.danger, Icons.fiber_manual_record_rounded, _elapsed),
      SentinelState.saving => (c.accent, Icons.lock_rounded, 'Sealing'),
    };
    final duration = SakMotion.of(context, SakMotion.standard);

    return Semantics(
      liveRegion: true,
      label: widget.state == SentinelState.recording ? 'Recording, $_elapsed' : label,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: widget.size,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: tint),
            duration: duration,
            curve: SakMotion.spring,
            builder: (context, color, _) => TweenAnimationBuilder<double>(
              // Re-targets from the current value, so a new reading never jumps.
              tween: Tween(end: widget.level.clamp(0.0, 1.0)),
              duration: duration,
              curve: SakMotion.spring,
              builder: (context, level, _) => AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) => CustomPaint(
                  painter: _OrbPainter(
                    tint: color ?? tint,
                    level: level,
                    ripple: widget.state == SentinelState.recording ? _ripple.value : null,
                    surface: c.surface,
                    track: c.separator,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: duration,
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: child),
                          ),
                          child: Icon(icon, key: ValueKey(icon), size: 36, color: color),
                        ),
                        const SizedBox(height: SakSpace.sm),
                        Text(
                          label,
                          style: context.type.titleMedium?.copyWith(
                            color: c.ink,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.tint, required this.level, required this.ripple, required this.surface, required this.track});

  final Color tint;
  final double level;
  final double? ripple;
  final Color surface;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final disc = outer * 0.70;

    // Ripple: one ring travelling out and fading, only while recording.
    final r = ripple;
    if (r != null) {
      final radius = disc + (outer - disc) * r;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tint.withValues(alpha: 0.5 * (1 - r)),
      );
    }

    // Halo that swells with the heard level.
    final halo = disc + (outer - disc) * (0.15 + 0.85 * level);
    canvas.drawCircle(center, halo, Paint()..color = tint.withValues(alpha: 0.10 + 0.10 * level));

    // The seal: a solid disc with a fine inner rule, like an embossed stamp.
    canvas.drawCircle(
      center,
      disc,
      Paint()
        ..color = surface
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 18),
    );
    canvas.drawCircle(center, disc, Paint()..color = surface);
    canvas.drawCircle(
      center,
      disc - 8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = tint.withValues(alpha: 0.35),
    );

    // Level arc around the disc, starting at the top.
    final arcRect = Rect.fromCircle(center: center, radius: disc + 6);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(arcRect, 0, 2 * math.pi, false, trackPaint);
    if (level > 0.005) {
      canvas.drawArc(arcRect, -math.pi / 2, 2 * math.pi * level, false, trackPaint..color = tint);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.tint != tint || old.level != level || old.ripple != ripple || old.surface != surface || old.track != track;
}

/// The distress score as a bar with a tick where the automatic trigger
/// fires, so the number has a meaning.
class ThresholdMeter extends StatelessWidget {
  const ThresholdMeter({super.key, required this.value, required this.threshold});

  final double value;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final over = value >= threshold;
    final percent = (value * 100).toStringAsFixed(0);
    return Semantics(
      label: 'Distress score $percent percent. Recording starts if it stays above ${(threshold * 100).round()} percent.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Distress score', style: context.type.bodySmall),
                const Spacer(),
                Text(
                  '$percent%',
                  style: context.type.labelMedium?.copyWith(
                    color: over ? c.danger : c.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: SakSpace.sm),
            SizedBox(
              height: 8,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(color: c.separator, borderRadius: BorderRadius.circular(4)),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: value.clamp(0.0, 1.0)),
                      duration: SakMotion.of(context, SakMotion.standard),
                      curve: SakMotion.spring,
                      builder: (context, v, _) => AnimatedContainer(
                        duration: SakMotion.of(context, SakMotion.quick),
                        width: box.maxWidth * v,
                        decoration: BoxDecoration(
                          color: over ? c.danger : c.accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    Positioned(
                      left: box.maxWidth * threshold - 1,
                      top: -3,
                      bottom: -3,
                      child: Container(width: 2, color: c.ink.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('Recording starts if it stays above ${(threshold * 100).round()}%', style: context.type.labelSmall),
          ],
        ),
      ),
    );
  }
}
