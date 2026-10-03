import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'dart:developer' as developer;

import '../core/evidence_encryptor.dart';

/// Decrypts one evidence record into a temporary plaintext file just long
/// enough to play it, then deletes that file the moment this screen closes.
/// The permanent ciphertext on disk is never touched or replaced.
class EvidencePlayerScreen extends StatefulWidget {
  const EvidencePlayerScreen({
    super.key,
    required this.cipherPath,
    required this.wrappedKeyB64,
    required this.label,
  });

  final String cipherPath;
  final String wrappedKeyB64;
  final String label;

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
      final plaintextBytes = await EvidenceEncryptor.decryptFile(
        widget.cipherPath,
        widget.wrappedKeyB64,
      );

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

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : (controller == null || !controller.value.isInitialized)
            ? const CircularProgressIndicator()
            : AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    VideoPlayer(controller),
                    VideoProgressIndicator(controller, allowScrubbing: true),
                  ],
                ),
              ),
      ),
      floatingActionButton: controller == null || !controller.value.isInitialized
          ? null
          : FloatingActionButton(
              onPressed: () {
                setState(() {
                  controller.value.isPlaying
                      ? controller.pause()
                      : controller.play();
                });
              },
              child: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
    );
  }
}
