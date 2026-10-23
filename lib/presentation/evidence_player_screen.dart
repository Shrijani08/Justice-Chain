import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'dart:developer' as developer;

import '../core/guardian_evidence_service.dart';
import 'design/app_theme.dart';
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
    this.checks,
    this.anchorSummary,
  });

  final String label;
  final Future<Uint8List> Function() loadPlaintext;

  /// Shown above the video when present (guardian verification results).
  final List<VerificationCheck>? checks;
  final String? anchorSummary;

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
      final tempPath =
          '${tempDir.path}/decrypted_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await File(tempPath).writeAsBytes(plaintextBytes);
      _tempPlaintextPath = tempPath;

      final controller = VideoPlayerController.file(File(tempPath));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        await _deleteTempFile();
        return;
      }

      setState(() {
        _controller = controller;
      });
      await controller.play();
    } catch (e) {
      developer.log(
        'Failed to decrypt/play evidence',
        error: e,
        name: 'JusticeChain.Player',
      );
      if (mounted) {
        setState(() {
          _error = 'Could not decrypt or play this clip.';
        });
      }
    }
  }

  Future<void> _deleteTempFile() async {
    final path = _tempPlaintextPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      developer.log(
        'Failed to delete decrypted temp file',
        error: e,
        name: 'JusticeChain.Player',
      );
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
    setState(() {
      controller.value.isPlaying ? controller.pause() : controller.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // Video is always shown on black, whatever the system appearance.
    const c = SakColors.dark;
    final ready = controller != null && controller.value.isInitialized;

    return Theme(
      data: buildSakTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: MonoText(widget.label, style: context.type.titleMedium?.copyWith(color: c.ink)),
          backgroundColor: Colors.black,
          foregroundColor: c.ink,
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (widget.checks != null)
                Reveal(
                  child: _VerificationPanel(
                    checks: widget.checks!,
                    anchorSummary: widget.anchorSummary,
                  ),
                ),
              Expanded(
                child: Center(
                  child: AnimatedSwitcher(
                    duration: SakMotion.of(context, SakMotion.standard),
                    child: _error != null
                        ? Padding(
                            key: const ValueKey('error'),
                            padding: const EdgeInsets.all(SakSpace.xl),
                            child: SakEmptyState(
                              icon: Icons.lock_outline_rounded,
                              title: _error!,
                              message: 'The sealed original is unchanged.',
                            ),
                          )
                        : !ready
                            ? Column(
                                key: const ValueKey('loading'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: SakSpace.lg),
                                  Text('Decrypting…', style: context.type.bodyMedium?.copyWith(color: c.inkSecondary)),
                                ],
                              )
                            : GestureDetector(
                                key: const ValueKey('video'),
                                onTap: _togglePlay,
                                child: AspectRatio(
                                  aspectRatio: controller.value.aspectRatio,
                                  child: VideoPlayer(controller),
                                ),
                              ),
                  ),
                ),
              ),
              if (ready) _Transport(controller: controller, onToggle: _togglePlay),
            ],
          ),
        ),
      ),
    );
  }
}

/// Play/pause, the scrubber and the time, on one bar under the video.
class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.onToggle});

  final VideoPlayerController controller;
  final VoidCallback onToggle;

  static String _time(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    const c = SakColors.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, SakSpace.lg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(SakSpace.xs, SakSpace.xs, SakSpace.lg, SakSpace.xs),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(100),
        ),
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) => Row(
            children: [
              IconButton(
                onPressed: onToggle,
                tooltip: value.isPlaying ? 'Pause' : 'Play',
                iconSize: 30,
                color: c.ink,
                icon: AnimatedSwitcher(
                  duration: SakMotion.of(context, SakMotion.quick),
                  transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                  child: Icon(
                    value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(value.isPlaying),
                  ),
                ),
              ),
              const SizedBox(width: SakSpace.xs),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    colors: VideoProgressColors(
                      playedColor: c.accent,
                      bufferedColor: c.inkTertiary.withValues(alpha: 0.5),
                      backgroundColor: c.separator,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SakSpace.md),
              Text(
                '${_time(value.position)} / ${_time(value.duration)}',
                style: context.type.labelSmall?.copyWith(
                  color: c.inkSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerificationPanel extends StatelessWidget {
  const _VerificationPanel({required this.checks, this.anchorSummary});

  final List<VerificationCheck> checks;
  final String? anchorSummary;

  @override
  Widget build(BuildContext context) {
    const c = SakColors.dark;
    final allPassed = checks.every((c) => c.passed == true);
    final tone = allPassed ? c.success : c.warning;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(SakSpace.lg, SakSpace.sm, SakSpace.lg, SakSpace.sm),
      padding: const EdgeInsets.all(SakSpace.lg),
      decoration: BoxDecoration(
        color: allPassed ? c.successSoft : c.warningSoft,
        borderRadius: BorderRadius.circular(SakRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(allPassed ? Icons.verified_rounded : Icons.gpp_maybe_rounded, color: tone, size: 22),
              const SizedBox(width: SakSpace.sm),
              Expanded(
                child: Text(
                  anchorSummary ?? (allPassed ? 'Verified' : 'Not fully verified'),
                  style: context.type.titleSmall?.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: SakSpace.md),
          for (final check in checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    check.passed == true
                        ? Icons.check_circle_rounded
                        : check.passed == false
                            ? Icons.cancel_rounded
                            : Icons.help_rounded,
                    size: 16,
                    color: check.passed == true
                        ? c.success
                        : check.passed == false
                            ? c.danger
                            : c.warning,
                  ),
                  const SizedBox(width: SakSpace.sm),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: check.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(text: ' — ${check.detail}'),
                        ],
                      ),
                      style: context.type.bodySmall?.copyWith(color: c.ink),
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
