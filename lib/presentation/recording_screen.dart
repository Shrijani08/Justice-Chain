import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../core/emergency_controller.dart';
import '../logic/safety_signals.dart';
import 'design/components.dart';
import 'design/sentinel.dart';
import 'design/tokens.dart';
import 'evidence_viewer_screen.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart' show SealDisc;

/// Shown for the whole of a recording, however it started. When the
/// recording ends it gives way to [SealedScreen].
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.startedAt});
  final DateTime startedAt;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final Timer _clock;
  EffectCleanup? _endWatch;
  bool _stopping = false;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    // Started here, not as a lazy field: nothing else reads it before
    // dispose, so a lazy one never ticked and the clock stayed at 00:00.
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
    _endWatch = effect(() {
      if (!isRecording.value) WidgetsBinding.instance.addPostFrameCallback((_) => _toSealed());
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    _endWatch?.call();
    super.dispose();
  }

  void _toSealed() {
    if (_left || !mounted) return;
    _left = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: SakMotion.of(context, const Duration(milliseconds: 420)),
        pageBuilder: (_, _, _) => SealedScreen(since: widget.startedAt),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await SafetyActions.stopRecording();
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt);
    final limit = EmergencyController.recordingTimeout;
    final shown = elapsed > limit ? limit : elapsed;

    // A recording can't be backed out of; it stops with Stop & seal or on
    // its own at the limit.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Ember.home,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Ember.home),
            Positioned(
              left: -100,
              right: -100,
              bottom: -260,
              height: 640,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, 0.2),
                    radius: 0.72,
                    colors: [Ember.emberStart, Ember.emberEnd, const Color(0xFF2E0A16), Ember.home.withValues(alpha: 0)],
                    stops: const [0, 0.3, 0.52, 1],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                child: FillScroll(
                  child: Column(
                    children: [
                      Glass(
                        radius: SakRadius.pill,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const PulseDot(color: Ember.alarm, size: 9, period: Duration(milliseconds: 1000)),
                            const SizedBox(width: 8),
                            Text(EmergencyController.isBackgroundRecording ? 'Recording in background' : 'Recording evidence', style: context.type.titleSmall?.copyWith(fontSize: 14)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 40),
                      const RecordingRibbon(height: 200),
                      const SizedBox(height: 28),
                      Semantics(
                        liveRegion: false,
                        label: 'Recording time ${shown.inSeconds} seconds',
                        child: ExcludeSemantics(
                          child: Text(
                            _mmss(shown),
                            style: const TextStyle(fontFamily: SakFont.mono, fontSize: 56, fontWeight: FontWeight.w500, letterSpacing: -1, color: Ember.ink),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 290),
                        child: Text(
                          'Camera and microphone are recording. It stops on its own at ${_mmss(limit).substring(1)} and seals.',
                          textAlign: TextAlign.center,
                          style: context.type.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14, color: const Color(0xB3F4ECEE)),
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const _SideBadge(icon: Icons.videocam_outlined, label: 'Camera on'),
                          _StopButton(stopping: _stopping, onTap: _stop),
                          const _SideBadge(icon: Icons.lock_outline_rounded, label: 'Encrypted'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(_stopping ? 'Sealing…' : 'Stop & seal', style: context.type.titleSmall?.copyWith(fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideBadge extends StatelessWidget {
  const _SideBadge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Ember.glass,
          border: Border.fromBorderSide(BorderSide(color: Ember.glassBorder)),
        ),
        child: Icon(icon, size: 22, color: Ember.ink),
      ),
    );
  }
}

class _StopButton extends StatefulWidget {
  const _StopButton({required this.stopping, required this.onTap});
  final bool stopping;
  final VoidCallback onTap;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

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
      label: 'Stop and seal',
      child: Pressable(
        enabled: !widget.stopping,
        child: GestureDetector(
          onTap: widget.stopping ? null : widget.onTap,
          child: SizedBox.square(
            dimension: 92,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) => Transform.scale(
                    scale: 1 + 0.8 * _ring.value,
                    child: Opacity(
                      opacity: 0.6 * (1 - _ring.value),
                      child: Container(
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x73F4ECEE), width: 2)),
                      ),
                    ),
                  ),
                ),
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: Alignment(-0.3, -0.4),
                      colors: [Color(0xFFF4ECEE), Color(0xFFE3C7CE), Color(0xFFC9A3AE)],
                      stops: [0, 0.6, 1],
                    ),
                    boxShadow: [BoxShadow(color: Color(0x998E1B32), blurRadius: 36)],
                  ),
                  child: Center(
                    child: widget.stopping
                        ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3, color: Ember.emberStart))
                        : Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(color: Ember.emberStart, borderRadius: BorderRadius.circular(8)),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// After a recording: the clip's seal and how far it has got, live from
/// the vault record.
class SealedScreen extends StatelessWidget {
  const SealedScreen({super.key, required this.since});
  final DateTime since;

  Map? _record(Box box) {
    Map? best;
    DateTime? bestAt;
    for (final v in box.values) {
      if (v is! Map || v['status'] == null || v['wrappedKey'] == null) continue;
      final at = DateTime.tryParse(v['timestamp'] as String? ?? '');
      if (at == null || at.isBefore(since.subtract(const Duration(seconds: 5)))) continue;
      if (bestAt == null || at.isAfter(bestAt)) {
        best = v;
        bestAt = at;
      }
    }
    return best;
  }

  static String _grouped(String hash) {
    final h = hash.length > 32 ? hash.substring(0, 32) : hash;
    final parts = [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4 > h.length ? h.length : i + 4)];
    return '${parts.join(' ')} …';
  }

  @override
  Widget build(BuildContext context) {
    final status = appStatus.watch(context);
    final failed = status.contains('Failed');
    return EmberScaffold(
      glows: const [
        Glow(color: Ember.wineGlow, width: 380, height: 380, left: 5, top: 40),
        Glow(color: Color(0xFF1E5A44), width: 240, height: 240, opacity: 0.35, right: -80, top: 300),
      ],
      child: ValueListenableBuilder(
        valueListenable: Hive.box('vault_box').listenable(),
        builder: (context, box, _) {
          final record = _record(box);
          final st = record?['status'] as String?;
          final guardians = (record?['guardianShares'] as Map?)?.length ?? 0;
          final uploaded = st == 'uploaded_to_ipfs' || st == 'anchored';
          final anchored = st == 'anchored';
          return FillScroll(
            child: Column(
              children: [
                const SizedBox(height: 32),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: SakMotion.reduced(context) ? 1 : 0, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: SakMotion.enter,
                  builder: (context, t, child) => Opacity(opacity: t, child: Transform.scale(scale: 1.4 - 0.4 * t, child: child)),
                  child: SealDisc(
                    size: 132,
                    icon: failed ? Icons.gpp_maybe_outlined : Icons.verified_user_outlined,
                    iconColor: failed ? Ember.attention : (record == null ? Ember.blush : Ember.sealed),
                  ),
                ),
                const SizedBox(height: 28),
                Text(failed ? 'Not sealed' : (record == null ? 'Sealing…' : 'Sealed.'), style: context.type.displayMedium),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Text(
                    failed
                        ? 'Something went wrong saving this clip. Try recording again.'
                        : "This recording can't be changed without its fingerprint changing too.",
                    textAlign: TextAlign.center,
                    style: context.type.bodyMedium?.copyWith(color: const Color(0xB3F4ECEE)),
                  ),
                ),
                const SizedBox(height: 28),
                Glass(
                  radius: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    children: [
                      _Step(done: record != null, label: record == null ? 'Encrypting on this phone…' : 'Encrypted on this phone', index: 0),
                      const Divider(height: 1, color: Color(0x14FFFFFF)),
                      _Step(
                        done: record != null,
                        label: guardians == 0
                            ? 'No guardians yet: add them to share keys'
                            : 'Key pieces ready for $guardians guardian${guardians == 1 ? '' : 's'}',
                        index: 1,
                        warn: record != null && guardians == 0,
                      ),
                      const Divider(height: 1, color: Color(0x14FFFFFF)),
                      _Step(done: uploaded, label: uploaded ? 'Uploaded to IPFS' : 'Uploading to IPFS…', index: 2),
                      const Divider(height: 1, color: Color(0x14FFFFFF)),
                      _Step(done: anchored, label: anchored ? 'Anchored on the ledger' : 'Anchoring on the ledger…', index: 3),
                    ],
                  ),
                ),
                if (record != null) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text('SHA-256 fingerprint', style: context.type.labelSmall),
                    ),
                  ),
                  Glass(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: MonoText(_grouped(record['hash'] as String? ?? ''), selectable: true, style: const TextStyle(fontSize: 13, height: 20 / 13)),
                    ),
                  ),
                ],
                const Spacer(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: SakButton(
                        label: 'View evidence',
                        style: SakButtonStyle.glass,
                        height: 56,
                        fontSize: 16,
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const EvidenceViewerScreen()),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SakButton(
                        label: 'Done',
                        style: SakButtonStyle.pearl,
                        height: 56,
                        fontSize: 16,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.done, required this.label, required this.index, this.warn = false});
  final bool done;
  final String label;
  final int index;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Reveal(
      index: index + 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: warn
                  ? const Icon(Icons.error_outline_rounded, size: 20, color: Ember.attention)
                  : done
                      ? const Icon(Icons.check_rounded, size: 20, color: Ember.sealed)
                      : const Padding(
                          padding: EdgeInsets.all(1),
                          child: CircularProgressIndicator(strokeWidth: 2, color: Ember.rose, backgroundColor: Color(0x33FFFFFF)),
                        ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: context.type.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
