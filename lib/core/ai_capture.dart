import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Experiment 1 of DOCS/08-10-2026 AI false trigger analysis.md: a record
/// of what the distress model hears and how it scores it, to tell a
/// preprocessing mismatch from bad training data.
///
/// Only in debug builds started with --dart-define=AI_CAPTURE=true. Every
/// 2 s window's scores go to `ai_capture/windows.csv` (and the log, as
/// `AI_CAPTURE …`); each window scoring at least the threshold is saved as
/// a 16 kHz WAV, exactly as the model saw it. While capturing, a confirmed
/// trigger is only logged ("WOULD TRIGGER"), so recordings don't pause the
/// listening. Files: app_flutter/ai_capture on the device.
///
/// With --dart-define=AI_CAPTURE_ALL=true as well, every window is saved,
/// not only the ones over the threshold (experiment 2's test set).
class AiCapture {
  AiCapture._();

  static const bool enabled = kDebugMode && bool.fromEnvironment('AI_CAPTURE');
  static const bool saveAll = enabled && bool.fromEnvironment('AI_CAPTURE_ALL');

  static Directory? _dir;
  static int _windowCount = 0;

  static Future<Directory> _directory() async {
    if (_dir != null) return _dir!;
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/ai_capture');
    await dir.create(recursive: true);
    final csv = File('${dir.path}/windows.csv');
    if (!await csv.exists()) {
      await csv.writeAsString('time,window,rms,label,p_distress,p_happy,p_normal,passed,would_trigger,wav\n');
    }
    return _dir = dir;
  }

  /// Logs one window. [probabilities] is empty for a window skipped as silence.
  static Future<void> window({
    required List<double> samples,
    required double rms,
    required String label,
    required List<double> probabilities,
    required bool passed,
    required bool wouldTrigger,
  }) async {
    try {
      final dir = await _directory();
      final now = DateTime.now();
      final n = ++_windowCount;
      String? wav;
      if (passed || saveAll) {
        final stamp = now.toIso8601String().replaceAll(':', '-').split('.').first;
        final score = probabilities.isEmpty ? 'silence' : 'd${(probabilities[0] * 100).round()}';
        wav = '${stamp}_w${n}_$score.wav';
        await File('${dir.path}/$wav').writeAsBytes(_wav(samples));
      }
      final p = probabilities.isEmpty ? ['', '', ''] : probabilities.map((v) => v.toStringAsFixed(4)).toList();
      final line = '${now.toIso8601String()},$n,${rms.toStringAsFixed(4)},$label,${p.join(',')},'
          '$passed,$wouldTrigger,${wav ?? ''}';
      await File('${dir.path}/windows.csv').writeAsString('$line\n', mode: FileMode.append);
      debugPrint('AI_CAPTURE $line${wouldTrigger ? '  <<< WOULD TRIGGER' : ''}');
    } catch (e) {
      debugPrint('AI_CAPTURE failed: $e');
    }
  }

  /// 16-bit mono PCM at 16 kHz. The samples were int16 / 32768, so this
  /// gives back the exact microphone values.
  static Uint8List _wav(List<double> samples) {
    final data = ByteData(44 + samples.length * 2);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, 16000, Endian.little);
    data.setUint32(28, 32000, Endian.little); // byte rate
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, (samples[i] * 32768).round().clamp(-32768, 32767), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
