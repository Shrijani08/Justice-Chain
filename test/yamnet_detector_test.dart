import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/yamnet_detector.dart';

void main() {
  final names = YamnetDetector.parseClassMap(File('assets/models/yamnet_class_map.csv').readAsStringSync());

  test('the bundled model is the checked YAMNet file', () {
    final hash = crypto.sha256.convert(File('assets/models/yamnet.tflite').readAsBytesSync()).toString();
    expect(hash, '4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf');
  });

  test('the class map has 521 names, quoted ones included', () {
    expect(names, hasLength(YamnetDetector.classCount));
    expect(names.first, 'Speech');
    expect(names[1], 'Child speech, kid speaking');
  });

  test('every distress class index points at the class it is named after', () {
    YamnetDetector.distressClasses.forEach((index, name) => expect(names[index], name));
  });

  group('score', () {
    // A window whose samples encode their own position, so a frame shows where it was cut.
    final window = List<double>.generate(YamnetDetector.windowLength, (i) => i / YamnetDetector.windowLength);

    List<double> scores(Map<int, double> set) {
      final s = List<double>.filled(YamnetDetector.classCount, 0.0);
      set.forEach((i, v) => s[i] = v);
      return s;
    }

    test('covers the 2 s window with three frames of 0.975 s', () {
      final starts = <int>[];
      YamnetDetector.score(window, (frame) {
        expect(frame, hasLength(YamnetDetector.frameLength));
        starts.add((frame.first * YamnetDetector.windowLength).round());
        return scores({});
      }, names);
      expect(starts, [0, 8200, 16400]);
      expect(starts.last + YamnetDetector.frameLength, YamnetDetector.windowLength, reason: 'reaches the end');
    });

    test('keeps each class at its strongest frame; distress is the strongest distress class', () {
      var call = 0;
      final result = YamnetDetector.score(window, (Float32List _) {
        call++;
        return switch (call) {
          1 => scores({0: 0.9, 11: 0.1}), // Speech, a little Screaming
          2 => scores({0: 0.4, 11: 0.6, 19: 0.3}), // Screaming, some Crying
          _ => scores({0: 0.5, 6: 0.2}), // Shout
        };
      }, names);
      expect(result.distress, closeTo(0.6, 1e-9));
      expect(result.topClass, 'Speech');
      expect(result.topScore, closeTo(0.9, 1e-9));
    });

    test('a class outside the distress list never counts', () {
      final result = YamnetDetector.score(window, (_) => scores({0: 0.99, 13: 0.95}), names); // Speech, Laughter
      expect(result.distress, 0.0);
      expect(result.distress >= YamnetDetector.threshold, isFalse);
    });

    test('refuses a window of the wrong length', () {
      expect(() => YamnetDetector.score(List.filled(16000, 0.0), (_) => scores({}), names), throwsArgumentError);
    });
  });
}
