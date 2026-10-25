import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/yamnet_detector.dart';
import '../logic/safety_signals.dart';
import 'design/components.dart';
import 'design/sentinel.dart';
import 'design/tokens.dart';
import 'home_screen.dart';

/// What the on-device AI hears right now, and the line it must cross.
class ListeningScreen extends StatelessWidget {
  const ListeningScreen({super.key});

  static String _label(String prediction) {
    if (prediction.isEmpty || prediction == 'none') return 'Quiet';
    return prediction[0].toUpperCase() + prediction.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final active = aiActive.watch(context);
    final level = aiConfidence.watch(context);
    final prediction = aiPrediction.watch(context);
    final ready = cameraReady.watch(context);
    final pct = (level * 100).round();
    final threshold = (YamnetDetector.threshold * 100).round();

    return EmberScaffold(
      background: const Color(0xFF08060A),
      glows: const [
        Glow(color: Color(0xFF4A1430), width: 460, height: 460, opacity: 0.7, left: -40, top: 120),
        Glow(color: Color(0xFF3A1A5C), width: 280, height: 280, opacity: 0.7, right: -100, bottom: 60),
      ],
      child: FillScroll(
        child: Column(
          children: [
            const SakTopBar(
              center: Glass(
                radius: SakRadius.pill,
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mic_none_rounded, size: 16, color: Color(0xFFFF8FA3)),
                    SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Sentinel', style: TextStyle(fontFamily: SakFont.body, fontSize: 14, fontWeight: FontWeight.w600, height: 1.1, color: Ember.ink)),
                        Text('On-device AI', style: TextStyle(fontFamily: SakFont.body, fontSize: 11, height: 1.1, color: Ember.ink2)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            SakOrb(size: 240, level: level, semanticLabel: active ? 'Listening, distress score $pct percent' : 'Not listening'),
            const SizedBox(height: 20),
            Text(active ? 'Hears' : 'Paused', style: context.type.bodyMedium?.copyWith(color: Ember.ink2)),
            const SizedBox(height: 4),
            AnimatedSwitcher(
              duration: SakMotion.of(context, SakMotion.quick),
              child: Text(
                active ? _label(prediction) : 'Not listening',
                key: ValueKey(prediction + active.toString()),
                style: context.type.displayMedium,
              ),
            ),
            const SizedBox(height: 20),
            if (active) WaveBars(level: level) else const SizedBox(height: 56),
            const SizedBox(height: 24),
            Glass(
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('Distress score', style: context.type.bodyMedium?.copyWith(fontSize: 14, color: Ember.ink2)),
                      const Spacer(),
                      MonoText('$pct%', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ThresholdMeter(value: level, threshold: YamnetDetector.threshold),
                  const SizedBox(height: 10),
                  Text(
                    'Recording starts if it stays above $threshold% for 2 of 3 seconds',
                    style: context.type.labelSmall,
                  ),
                ],
              ),
            ),
            const Spacer(),
            const SizedBox(height: 24),
            _RecordNowButton(enabled: ready),
            const SizedBox(height: 10),
            Text(ready ? 'Start recording now' : 'Camera not ready', style: context.type.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _RecordNowButton extends StatefulWidget {
  const _RecordNowButton({required this.enabled});
  final bool enabled;

  @override
  State<_RecordNowButton> createState() => _RecordNowButtonState();
}

class _RecordNowButtonState extends State<_RecordNowButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!SakMotion.reduced(context) && !_ring.isAnimating) _ring.repeat();
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: 'Start recording now',
      child: Pressable(
        enabled: widget.enabled,
        child: GestureDetector(
          onTap: widget.enabled ? SafetyActions.startRecording : null,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.45,
            child: SizedBox.square(
              dimension: 76,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _ring,
                    builder: (context, _) => Transform.scale(
                      scale: 1 + 0.7 * _ring.value,
                      child: Opacity(
                        opacity: 0.55 * (1 - _ring.value),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFC98597), width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-0.3, -0.4),
                        colors: [Color(0xFFA8384F), Color(0xFF7A1A30), Color(0xFF4A0D1C)],
                        stops: [0, 0.55, 1],
                      ),
                      border: Border.all(color: const Color(0x38FF8CA0)),
                      boxShadow: const [BoxShadow(color: Color(0x997A1A30), blurRadius: 34)],
                    ),
                    child: const Center(child: Icon(Icons.videocam_outlined, color: Colors.white, size: 28)),
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
