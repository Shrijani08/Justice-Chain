import 'dart:math' as math;

class AudioPreprocessor {
  static const int sampleRate = 16000;
  static const int chunkSeconds = 2;
  static const int chunkSampleCount = sampleRate * chunkSeconds;
  static const int nFft = 2048;
  static const int hopLength = 512;
  static const int melBins = 128;
  static const int outputWidth = 128;
  static const double preEmphasis = 0.97;
  static const double silenceRmsThreshold = 0.015;
  static const double targetRms = 0.15;
  static const double amin = 1.0e-10;
  static const double topDb = 80.0;

  static Map<String, dynamic> preprocess(List<double> samples) {
    final fixed = _fixLength(samples, chunkSampleCount);
    final inputRms = _rms(fixed);

    if (inputRms < silenceRmsThreshold) {
      return {
        'tensor': _toTensor(_zeros(melBins, outputWidth)),
        'rms': inputRms,
        'silent': true,
      };
    }

    final emphasized = _preEmphasis(fixed);
    final normalized = _rmsNormalize(emphasized);
    final gated = _noiseGate(normalized, silenceRmsThreshold);
    final powerSpectrogram = _stftPower(gated);
    final melSpectrogram = _melSpectrogram(powerSpectrogram);
    final dbSpectrogram = _powerToDb(melSpectrogram);
    final resized = _resizeBilinear(dbSpectrogram, melBins, outputWidth);
    final minMaxNormalized = _minMaxNormalize(resized);

    return {
      'tensor': _toTensor(minMaxNormalized),
      'rms': inputRms,
      'silent': false,
    };
  }

  static List<double> _fixLength(List<double> samples, int targetLength) {
    if (samples.length == targetLength) return List<double>.from(samples);

    if (samples.length > targetLength) {
      return samples.sublist(samples.length - targetLength);
    }

    final padded = List<double>.filled(targetLength, 0.0);
    final start = targetLength - samples.length;
    for (var i = 0; i < samples.length; i++) {
      padded[start + i] = samples[i];
    }
    return padded;
  }

  static double _rms(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    var sumSquares = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    return math.sqrt(sumSquares / samples.length);
  }

  static List<double> _preEmphasis(List<double> samples) {
    if (samples.isEmpty) return <double>[];

    final output = List<double>.filled(samples.length, 0.0);
    output[0] = samples[0];
    for (var i = 1; i < samples.length; i++) {
      output[i] = samples[i] - (preEmphasis * samples[i - 1]);
    }
    return output;
  }

  static List<double> _rmsNormalize(List<double> samples) {
    final currentRms = _rms(samples);
    if (currentRms <= 0.0) return samples;

    final gain = targetRms / currentRms;
    return List<double>.generate(
      samples.length,
      (index) => (samples[index] * gain).clamp(-1.0, 1.0).toDouble(),
    );
  }

  static List<double> _noiseGate(List<double> samples, double threshold) {
    return List<double>.generate(samples.length, (index) {
      final sample = samples[index];
      return sample.abs() < threshold ? 0.0 : sample;
    });
  }

  static List<List<double>> _stftPower(List<double> samples) {
    final centered = List<double>.filled(samples.length + nFft, 0.0);
    final pad = nFft ~/ 2;
    for (var i = 0; i < samples.length; i++) {
      centered[i + pad] = samples[i];
    }

    final frameCount = 1 + ((centered.length - nFft) ~/ hopLength);
    final window = _hannWindow(nFft);
    final frames = List<List<double>>.generate(
      frameCount,
      (_) => List<double>.filled((nFft ~/ 2) + 1, 0.0),
    );

    for (var frame = 0; frame < frameCount; frame++) {
      final start = frame * hopLength;
      final real = List<double>.filled(nFft, 0.0);
      final imag = List<double>.filled(nFft, 0.0);

      for (var i = 0; i < nFft; i++) {
        real[i] = centered[start + i] * window[i];
      }

      _fftInPlace(real, imag);

      for (var bin = 0; bin <= nFft ~/ 2; bin++) {
        frames[frame][bin] = (real[bin] * real[bin]) + (imag[bin] * imag[bin]);
      }
    }

    return frames;
  }

  static List<double> _hannWindow(int length) {
    return List<double>.generate(
      length,
      (index) => 0.5 - (0.5 * math.cos((2.0 * math.pi * index) / length)),
    );
  }

  static void _fftInPlace(List<double> real, List<double> imag) {
    final n = real.length;
    var j = 0;

    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;

      if (i < j) {
        final tempReal = real[i];
        final tempImag = imag[i];
        real[i] = real[j];
        imag[i] = imag[j];
        real[j] = tempReal;
        imag[j] = tempImag;
      }
    }

    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2.0 * math.pi / length;
      final wLengthReal = math.cos(angle);
      final wLengthImag = math.sin(angle);

      for (var i = 0; i < n; i += length) {
        var wReal = 1.0;
        var wImag = 0.0;
        final halfLength = length >> 1;

        for (var k = 0; k < halfLength; k++) {
          final evenIndex = i + k;
          final oddIndex = evenIndex + halfLength;

          final oddReal = real[oddIndex] * wReal - imag[oddIndex] * wImag;
          final oddImag = real[oddIndex] * wImag + imag[oddIndex] * wReal;

          real[oddIndex] = real[evenIndex] - oddReal;
          imag[oddIndex] = imag[evenIndex] - oddImag;
          real[evenIndex] += oddReal;
          imag[evenIndex] += oddImag;

          final nextWReal = wReal * wLengthReal - wImag * wLengthImag;
          final nextWImag = wReal * wLengthImag + wImag * wLengthReal;
          wReal = nextWReal;
          wImag = nextWImag;
        }
      }
    }
  }

  static List<List<double>> _melSpectrogram(List<List<double>> powerSpec) {
    final filters = _melFilterBank();
    final frameCount = powerSpec.length;
    final mel = _zeros(melBins, frameCount);

    for (var melIndex = 0; melIndex < melBins; melIndex++) {
      final filter = filters[melIndex];
      for (var frame = 0; frame < frameCount; frame++) {
        var energy = 0.0;
        for (var bin = 0; bin < filter.length; bin++) {
          energy += powerSpec[frame][bin] * filter[bin];
        }
        mel[melIndex][frame] = energy;
      }
    }

    return mel;
  }

  static List<List<double>> _melFilterBank() {
    final fftBinCount = (nFft ~/ 2) + 1;
    final lowMel = _hzToMel(0.0);
    final highMel = _hzToMel(sampleRate / 2.0);
    final melPoints = List<double>.generate(
      melBins + 2,
      (index) => lowMel + (highMel - lowMel) * index / (melBins + 1),
    );
    final hzPoints = melPoints.map(_melToHz).toList();
    final bins = hzPoints
        .map((hz) => ((nFft + 1) * hz / sampleRate).floor())
        .map((bin) => bin.clamp(0, fftBinCount - 1))
        .toList();

    final filters = List<List<double>>.generate(
      melBins,
      (_) => List<double>.filled(fftBinCount, 0.0),
    );

    for (var melIndex = 1; melIndex <= melBins; melIndex++) {
      final left = bins[melIndex - 1];
      final center = bins[melIndex];
      final right = bins[melIndex + 1];

      if (center > left) {
        for (var bin = left; bin < center; bin++) {
          filters[melIndex - 1][bin] = (bin - left) / (center - left);
        }
      }

      if (right > center) {
        for (var bin = center; bin < right; bin++) {
          filters[melIndex - 1][bin] = (right - bin) / (right - center);
        }
      }
    }

    return filters;
  }

  static double _hzToMel(double hz) {
    return 2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
  }

  static double _melToHz(double mel) {
    return (700.0 * (math.pow(10.0, mel / 2595.0) - 1.0)).toDouble();
  }

  static List<List<double>> _powerToDb(List<List<double>> melPower) {
    var maxPower = amin;
    for (final row in melPower) {
      for (final value in row) {
        if (value > maxPower) maxPower = value;
      }
    }

    final logReference = 10.0 * math.log(maxPower) / math.ln10;
    final minDb = -topDb;

    return List<List<double>>.generate(melPower.length, (row) {
      return List<double>.generate(melPower[row].length, (column) {
        final power = math.max(melPower[row][column], amin);
        final db = (10.0 * math.log(power) / math.ln10) - logReference;
        return math.max(db, minDb);
      });
    });
  }

  static List<List<double>> _resizeBilinear(
    List<List<double>> source,
    int targetHeight,
    int targetWidth,
  ) {
    final sourceHeight = source.length;
    final sourceWidth = source.first.length;
    final output = _zeros(targetHeight, targetWidth);

    for (var y = 0; y < targetHeight; y++) {
      final sourceY = targetHeight == 1
          ? 0.0
          : y * (sourceHeight - 1) / (targetHeight - 1);
      final y0 = sourceY.floor();
      final y1 = math.min(y0 + 1, sourceHeight - 1);
      final yWeight = sourceY - y0;

      for (var x = 0; x < targetWidth; x++) {
        final sourceX = targetWidth == 1
            ? 0.0
            : x * (sourceWidth - 1) / (targetWidth - 1);
        final x0 = sourceX.floor();
        final x1 = math.min(x0 + 1, sourceWidth - 1);
        final xWeight = sourceX - x0;

        final top = source[y0][x0] * (1.0 - xWeight) + source[y0][x1] * xWeight;
        final bottom =
            source[y1][x0] * (1.0 - xWeight) + source[y1][x1] * xWeight;

        output[y][x] = top * (1.0 - yWeight) + bottom * yWeight;
      }
    }

    return output;
  }

  static List<List<double>> _minMaxNormalize(List<List<double>> source) {
    var minValue = double.infinity;
    var maxValue = -double.infinity;

    for (final row in source) {
      for (final value in row) {
        if (value < minValue) minValue = value;
        if (value > maxValue) maxValue = value;
      }
    }

    final range = maxValue - minValue;
    if (range.abs() < 1.0e-12) {
      return _zeros(source.length, source.first.length);
    }

    return List<List<double>>.generate(source.length, (row) {
      return List<double>.generate(
        source[row].length,
        (column) => (source[row][column] - minValue) / range,
      );
    });
  }

  static List<List<double>> _zeros(int rows, int columns) {
    return List<List<double>>.generate(
      rows,
      (_) => List<double>.filled(columns, 0.0),
    );
  }

  static List<List<List<List<double>>>> _toTensor(List<List<double>> image) {
    return [
      List<List<List<double>>>.generate(
        image.length,
        (row) => List<List<double>>.generate(
          image[row].length,
          (column) => [image[row][column]],
        ),
      ),
    ];
  }
}

Map<String, dynamic> preprocessAudioChunk(List<double> samples) {
  return AudioPreprocessor.preprocess(samples);
}
