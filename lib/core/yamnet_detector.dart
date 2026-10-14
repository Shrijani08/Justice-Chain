import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Scores one model frame: [YamnetDetector.frameLength] samples in, one
/// score per class out.
typedef FrameClassifier = List<double> Function(Float32List frame);

/// What YAMNet heard in one 2 s window.
class YamnetResult {
  const YamnetResult({required this.distress, required this.topClass, required this.topScore});

  /// The highest score of the distress classes, 0..1.
  final double distress;

  /// YAMNet's strongest class in the window, e.g. "Speech" or "Screaming".
  final String topClass;
  final double topScore;
}

/// The automatic trigger's ear: Google's pretrained YAMNet (AudioSet, 521
/// classes, Apache 2.0; see assets/models/YAMNET_NOTICE.txt). Our own
/// distress model called ordinary speech "distress" about 100 times an
/// hour on a real phone; YAMNet told speech from screaming on the same
/// clips (DOCS/08-10-2026 AI false trigger analysis.md).
///
/// A 2 s window is covered by three YAMNet frames of 0.975 s; each class
/// keeps its strongest frame, and the window's distress score is the
/// strongest of [distressClasses].
class YamnetDetector {
  static const modelAsset = 'assets/models/yamnet.tflite';
  static const classMapAsset = 'assets/models/yamnet_class_map.csv';
  static const frameLength = 15600; // 0.975 s at 16 kHz
  static const windowLength = 32000; // 2 s at 16 kHz
  static const frameOffsets = [0, 8200, windowLength - frameLength];
  static const classCount = 521;

  /// A window at or above this distress score passes (set from the
  /// experiments; checked in the validation session).
  static const threshold = 0.2;

  /// Index in YAMNet's class map, and its name there.
  static const distressClasses = <int, String>{
    6: 'Shout',
    7: 'Bellow',
    9: 'Yell',
    10: 'Children shouting',
    11: 'Screaming',
    19: 'Crying, sobbing',
    21: 'Whimper',
    22: 'Wail, moan',
  };

  Interpreter? _interpreter;
  List<String> _classNames = const [];

  bool get isLoaded => _interpreter != null;

  Future<void> load() async {
    if (_interpreter != null) return;
    final interpreter = await Interpreter.fromAsset(modelAsset, options: InterpreterOptions()..threads = 2);
    _classNames = parseClassMap(await rootBundle.loadString(classMapAsset));
    // A zero frame proves the model runs before monitoring depends on it.
    _runFrame(interpreter, Float32List(frameLength));
    _interpreter = interpreter;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }

  YamnetResult scoreWindow(List<double> window) {
    final interpreter = _interpreter;
    if (interpreter == null) throw StateError('YAMNet is not loaded');
    return score(window, (frame) => _runFrame(interpreter, frame), _classNames);
  }

  static List<double> _runFrame(Interpreter interpreter, Float32List frame) {
    final output = [List<double>.filled(classCount, 0.0)];
    interpreter.run(frame, output);
    return output.first;
  }

  /// The scoring rule, separate from the interpreter so it can be tested.
  @visibleForTesting
  static YamnetResult score(List<double> window, FrameClassifier classify, List<String> classNames) {
    if (window.length != windowLength) {
      throw ArgumentError('A window is $windowLength samples, got ${window.length}');
    }
    final best = List<double>.filled(classCount, 0.0);
    for (final offset in frameOffsets) {
      final frame = Float32List.fromList(window.sublist(offset, offset + frameLength));
      final scores = classify(frame);
      for (var i = 0; i < classCount; i++) {
        best[i] = math.max(best[i], scores[i]);
      }
    }
    var top = 0;
    for (var i = 1; i < classCount; i++) {
      if (best[i] > best[top]) top = i;
    }
    return YamnetResult(
      distress: distressClasses.keys.map((i) => best[i]).reduce(math.max),
      topClass: top < classNames.length ? classNames[top] : 'class $top',
      topScore: best[top],
    );
  }

  /// Display names from yamnet_class_map.csv (index,mid,display_name; names
  /// with commas are quoted).
  static List<String> parseClassMap(String csv) {
    final names = <String>[];
    for (final line in csv.split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final rest = trimmed.substring(trimmed.indexOf(',', trimmed.indexOf(',') + 1) + 1);
      names.add(rest.startsWith('"') ? rest.substring(1, rest.length - 1) : rest);
    }
    return names;
  }
}
