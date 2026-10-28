import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'dart:developer' as developer;

import '../core/guardian_evidence_service.dart';
import '../core/plain_summary.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// Decrypts one evidence record into a temporary plaintext file just long
/// enough to play it, then deletes that file the moment this screen closes.
/// The permanent ciphertext on disk is never touched or replaced.
class EvidencePlayerScreen extends StatefulWidget {
  const EvidencePlayerScreen({
    super.key,
    required this.label,
    required this.loadPlaintext,
    this.title,
    this.checks,
    this.summary,
  });

  /// The fingerprint (or name) under the title.
  final String label;
  final String? title;
  final Future<Uint8List> Function() loadPlaintext;

  /// Shown above the video when present (guardian verification results).
  final List<VerificationCheck>? checks;

  /// The result in plain words, above the checks. Without [checks] (the
  /// owner's own clip, which only opens if it matches its fingerprint) it is
  /// shown once the clip has opened.
  final PlainSummary? summary;

  @override
  State<EvidencePlayerScreen> createState() => _EvidencePlayerScreenState();
}

class _EvidencePlayerScreenState extends State<EvidencePlayerScreen> {
  VideoPlayerController? _controller;
  String? _tempPlaintextPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _decryptAndLoad();
  }

  Future<void> _decryptAndLoad() async {
    try {
      final plaintextBytes = await widget.loadPlaintext();

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/decrypted_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await File(tempPath).writeAsBytes(plaintextBytes);
      _tempPlaintextPath = tempPath;

      final controller = VideoPlayerController.file(File(tempPath));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        await _deleteTempFile();
        return;
      }

      setState(() => _controller = controller);
      await controller.play();
    } catch (e) {
      developer.log('Failed to decrypt/play evidence', error: e, name: 'JusticeChain.Player');
      if (mounted) setState(() => _error = 'Could not decrypt or play this clip.');
    }
  }

  Future<void> _deleteTempFile() async {
    final path = _tempPlaintextPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      developer.log('Failed to delete decrypted temp file', error: e, name: 'JusticeChain.Player');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    unawaited(_deleteTempFile());
    super.dispose();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    setState(() => controller.value.isPlaying ? controller.pause() : controller.play());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return EmberScaffold(
      background: Ember.black,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SakTopBar(
            center: Column(
              children: [
                Text(widget.title ?? widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleSmall),
                if (widget.title != null) MonoText(widget.label, style: const TextStyle(fontSize: 12, color: Color(0x99F4ECEE))),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (widget.summary != null && (widget.checks != null || ready)) ...[
            Reveal(child: _VerificationPanel(summary: widget.summary!, checks: widget.checks ?? const [])),
            const SizedBox(height: 14),
          ],
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(center: Alignment(0, -0.2), radius: 0.9, colors: [Color(0xFF2A2224), Color(0xFF0B0909)]),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AnimatedSwitcher(
                        duration: SakMotion.of(context, SakMotion.standard),
                        child: _error != null
                            ? SakEmptyState(
                                key: const ValueKey('error'),
                                icon: Icons.lock_outline_rounded,
                                title: _error!,
                                message: 'The sealed original is unchanged.',
                              )
                            : !ready
                                ? Column(
                                    key: const ValueKey('loading'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const CircularProgressIndicator(),
                                      const SizedBox(height: SakSpace.lg),
                                      Text('Decrypting…', style: context.type.bodyMedium?.copyWith(color: Ember.ink2)),
                                    ],
                                  )
                                : GestureDetector(
                                    key: const ValueKey('video'),
                                    onTap: _togglePlay,
                                    child: AspectRatio(aspectRatio: controller.value.aspectRatio, child: VideoPlayer(controller)),
                                  ),
                      ),
                    ),
                    const Positioned(
                      left: 14,
                      top: 14,
                      child: Glass(
                        radius: 8,
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        child: Text('Decrypted only while open', style: TextStyle(fontFamily: SakFont.body, fontSize: 12, color: Color(0x99F4ECEE))),
                      ),
                    ),
                    if (ready)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (context, value, _) => IgnorePointer(
                          ignoring: value.isPlaying,
                          child: AnimatedOpacity(
                            opacity: value.isPlaying ? 0 : 1,
                            duration: SakMotion.of(context, SakMotion.quick),
                            child: Center(
                              child: Semantics(
                                button: true,
                                label: 'Play',
                                child: GestureDetector(
                                  onTap: _togglePlay,
                                  child: Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0x24FFFFFF),
                                      border: Border.all(color: const Color(0x40FFFFFF)),
                                    ),
                                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (ready) _Transport(controller: controller, onToggle: _togglePlay),
        ],
      ),
    );
  }
}

/// Play/pause, the scrubber and the time, on one glass bar.
class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.onToggle});

  final VideoPlayerController controller;
  final VoidCallback onToggle;

  static String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(6, 6, 18, 6),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final total = value.duration.inMilliseconds;
          final played = total == 0 ? 0.0 : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
          return Row(
            children: [
              Semantics(
                button: true,
                label: value.isPlaying ? 'Pause' : 'Play',
                child: GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Ember.ink),
                    child: Icon(value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Ember.onPearl, size: 22),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    void seek(double dx) {
                      final f = (dx / box.maxWidth).clamp(0.0, 1.0);
                      controller.seekTo(Duration(milliseconds: (total * f).round()));
                    }

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => seek(d.localPosition.dx),
                      onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
                      child: SizedBox(
                        height: 44,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          clipBehavior: Clip.none,
                          children: [
                            Container(height: 4, decoration: BoxDecoration(color: const Color(0x29FFFFFF), borderRadius: BorderRadius.circular(2))),
                            Container(
                              width: box.maxWidth * played,
                              height: 4,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(2),
                                gradient: const LinearGradient(colors: [Color(0xFFFF8FA3), Color(0xFFFF4D6D)]),
                              ),
                            ),
                            Positioned(
                              left: box.maxWidth * played - 7,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  boxShadow: [BoxShadow(color: Color(0xCCFF4D6D), blurRadius: 10)],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              MonoText('${_time(value.position)} / ${_time(value.duration)}', style: const TextStyle(fontSize: 12, color: Color(0xB3F4ECEE))),
            ],
          );
        },
      ),
    );
  }
}

class _VerificationPanel extends StatefulWidget {
  const _VerificationPanel({required this.summary, required this.checks});

  final PlainSummary summary;
  final List<VerificationCheck> checks;

  @override
  State<_VerificationPanel> createState() => _VerificationPanelState();
}

class _VerificationPanelState extends State<_VerificationPanel> {
  bool _showChecks = false;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final checks = widget.checks;
    final (tone, icon) = switch (summary.tone) {
      SummaryTone.verified => (Ember.sealed, Icons.verified_user_outlined),
      SummaryTone.failed => (Ember.alertText, Icons.gpp_bad_outlined),
      SummaryTone.unchecked => (Ember.attention, Icons.gpp_maybe_outlined),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [tone.withValues(alpha: 0.18), tone.withValues(alpha: 0.05)]),
        border: Border.all(color: tone.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: tone, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(summary.headline, style: context.type.titleSmall)),
            ],
          ),
          for (final note in summary.notes)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 32),
              child: Text(note, style: const TextStyle(fontFamily: SakFont.body, fontSize: 13, height: 18 / 13, color: Ember.ink2)),
            ),
          if (checks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 22),
              child: TextButton(
                onPressed: () => setState(() => _showChecks = !_showChecks),
                child: Text(_showChecks ? 'Hide the technical checks' : 'Show the ${checks.length} technical checks'),
              ),
            ),
          if (_showChecks)
          for (final check in checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      check.passed == true
                          ? Icons.check_rounded
                          : check.passed == false
                              ? Icons.close_rounded
                              : Icons.help_outline_rounded,
                      size: 16,
                      color: check.passed == true
                          ? Ember.sealed
                          : check.passed == false
                              ? Ember.alertText
                              : Ember.attention,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: check.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: ' — ${check.detail}'),
                      ]),
                      style: const TextStyle(fontFamily: SakFont.body, fontSize: 13, height: 18 / 13, color: Ember.ink),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
