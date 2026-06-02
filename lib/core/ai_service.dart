import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../logic/safety_signals.dart';

typedef DistressDetectedCallback = Future<void> Function(AIDistressEvent event);

class AIDistressEvent {
  const AIDistressEvent({
    required this.confidence,
    required this.label,
    required this.isSimulated,
  });

  final double confidence;
  final String label;
  final bool isSimulated;
}

class AIPrediction {
  const AIPrediction({
    required this.label,
    required this.confidence,
    required this.distressConfidence,
    required this.probabilities,
  });

  final String label;
  final double confidence;
  final double distressConfidence;
  final List<double> probabilities;
}

class AIService {
  AIService._internal();

  static final AIService instance = AIService._internal();

  factory AIService() => instance;

  static const String _modelAssetPath = 'assets/models/distress_model.tflite';
  static const List<String> _classes = ['distress', 'happy', 'normal'];
  static const double distressThreshold = 0.70;

  static const int _sampleRate = 16000;
  static const int _windowSampleCount = 32000;
  static const int _inferenceStrideSamples = _sampleRate;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final ListQueue<double> _rollingSamples = ListQueue<double>();

  Interpreter? _interpreter;
  StreamSubscription<Uint8List>? _audioSubscription;
  DistressDetectedCallback? _onDistressDetected;

  bool _isModelLoaded = false;
  bool _isMonitoring = false;
  bool _isTriggering = false;
  bool _isPreprocessing = false;
  bool _isInitializing = false;
  bool _isPausedForRecording = false;
  int _samplesSinceLastInference = 0;
  String? _lastModelError;

  bool get isModelLoaded => _isModelLoaded;
  bool get isMonitoring => _isMonitoring;

  Future<void> initModel() async {
    if (_isModelLoaded || _isInitializing) return;

    _isInitializing = true;
    aiStatus.value = 'Loading AI 1D distress model...';

    try {
      final options = InterpreterOptions()..threads = 2;

      _interpreter = await Interpreter.fromAsset(
        _modelAssetPath,
        options: options,
      );

      _interpreter!.resizeInputTensor(0, const [1, 32000, 1]);
      _interpreter!.allocateTensors();
      _runModelSelfTest();

      _isModelLoaded = true;
      aiModelReady.value = true;
      aiStatus.value = 'AI model ready';
      aiConfidence.value = 0.0;
      aiPrediction.value = 'none';
      _lastModelError = null;

      developer.log('1D CNN TFLite model loaded', name: 'JusticeChain.AI');
    } catch (error, stackTrace) {
      _isModelLoaded = false;
      aiModelReady.value = false;
      aiActive.value = false;
      _lastModelError = error.toString().split('\n').first;
      aiStatus.value = 'AI model load failed: $_lastModelError';

      developer.log(
        'Failed to initialize 1D TFLite interpreter: $error',
        name: 'JusticeChain.AI',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> startMonitoring({
    DistressDetectedCallback? onDistressDetected,
  }) async {
    if (onDistressDetected != null) {
      _onDistressDetected = onDistressDetected;
    }

    if (_isMonitoring || _isPausedForRecording) return;

    await initModel();
    if (!_isModelLoaded || _interpreter == null) {
      aiStatus.value = _lastModelError == null
          ? 'AI monitoring paused: model unavailable'
          : 'AI monitoring paused: $_lastModelError';
      return;
    }

    final hasMicrophonePermission = await _audioRecorder.hasPermission();
    if (!hasMicrophonePermission) {
      aiStatus.value = 'AI monitoring paused: microphone permission needed';
      return;
    }

    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: false,
        noiseSuppress: false,
        streamBufferSize: 2048,
      ),
    );

    _rollingSamples.clear();
    _samplesSinceLastInference = 0;
    _isMonitoring = true;
    aiActive.value = true;
    aiStatus.value = 'AI listening at 16 kHz';

    _audioSubscription = stream.listen(
      _handlePcmBytes,
      onError: (Object error, StackTrace stackTrace) {
        aiStatus.value = 'AI microphone stream error';
        aiActive.value = false;
      },
      cancelOnError: false,
    );
  }

  Future<void> stopMonitoring({String status = 'AI monitoring stopped'}) async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    if (_isMonitoring) {
      try {
        await _audioRecorder.stop();
      } catch (error) {
        developer.log(
          'Audio recorder stop ignored: $error',
          name: 'JusticeChain.AI',
        );
      }
    }

    _rollingSamples.clear();
    _samplesSinceLastInference = 0;
    _isMonitoring = false;
    _isPreprocessing = false;
    aiActive.value = false;
    aiStatus.value = _isModelLoaded ? status : aiStatus.value;
  }

  Future<void> pauseForRecording() async {
    if (_isPausedForRecording) return;
    _isPausedForRecording = true;
    await stopMonitoring(status: 'AI paused while recording');
  }

  Future<void> resumeAfterRecording() async {
    if (!_isPausedForRecording) return;
    _isPausedForRecording = false;
    await startMonitoring();
  }

  void _handlePcmBytes(Uint8List bytes) {
    if (bytes.isEmpty || !_isMonitoring || isRecording.value) return;

    final samples = _pcm16BytesToSamples(bytes);

    for (final sample in samples) {
      _rollingSamples.addLast(sample);
      while (_rollingSamples.length > _windowSampleCount) {
        _rollingSamples.removeFirst();
      }
    }

    _samplesSinceLastInference += samples.length;

    if (_rollingSamples.length == _windowSampleCount &&
        _samplesSinceLastInference >= _inferenceStrideSamples &&
        !_isPreprocessing) {
      _samplesSinceLastInference = 0;
      final window = List<double>.from(_rollingSamples);
      unawaited(_runRealtimeInference(window));
    }
  }

  List<double> _pcm16BytesToSamples(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    final sampleCount = bytes.length ~/ 2;
    return List<double>.generate(sampleCount, (index) {
      final value = byteData.getInt16(index * 2, Endian.little);
      return value / 32768.0;
    });
  }

  Future<void> _runRealtimeInference(List<double> samples) async {
    if (!_isModelLoaded || _interpreter == null || isRecording.value) return;

    _isPreprocessing = true;
    aiStatus.value = 'AI executing 1D CNN prediction';

    try {
      double sumSquares = samples.fold(0.0, (sum, val) => sum + (val * val));
      double rms = math.sqrt(sumSquares / samples.length);

      if (rms < 0.005) {
        aiStatus.value = 'AI listening: environment quiet';
        aiPrediction.value = 'silence';
        aiConfidence.value = 0.0;
        return;
      }

      final prediction = evaluateDistressSignals(samples);
      aiPrediction.value = prediction.label;
      aiConfidence.value = prediction.confidence;

      final percent = (prediction.confidence * 100).toStringAsFixed(0);
      aiStatus.value = 'AI prediction: ${prediction.label} ($percent%)';

      // FIXED: Instant verification check. Fires event immediately if prediction matches and clears threshold
      if (prediction.label.toLowerCase() == 'distress' &&
          prediction.confidence >= distressThreshold) {
        developer.log(
          '🔥 INSTANT THRESHOLD PASSED: Distress confirmed ($percent%)',
          name: 'JusticeChain.AI',
        );

        await _notifyDistressDetected(
          AIDistressEvent(
            confidence: prediction.distressConfidence,
            label: prediction.label,
            isSimulated: false,
          ),
        );
      }
    } catch (error, stackTrace) {
      aiStatus.value = 'AI inference pipeline error';
      developer.log(
        'Realtime AI 1D pipeline failed: $error',
        name: 'JusticeChain.AI',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isPreprocessing = false;
    }
  }

  AIPrediction evaluateDistressSignals(List<double> inputRawAudio) {
    if (!_isModelLoaded || _interpreter == null) {
      return const AIPrediction(
        label: 'unavailable',
        confidence: 0.0,
        distressConfidence: 0.0,
        probabilities: <double>[],
      );
    }

    var inputTensor = [
      inputRawAudio.map((val) => [val]).toList(),
    ];

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final outputTensor = _buildFilledTensor(outputShape, 0.0);

    _interpreter!.run(inputTensor, outputTensor);

    final rawValues = _flattenNumericValues(outputTensor);
    final prediction = _parsePrediction(rawValues);

    return prediction;
  }

  void _runModelSelfTest() {
    final zeroInput = [
      List.generate(32000, (_) => [0.0]),
    ];
    final outputTensor = _buildFilledTensor(
      _interpreter!.getOutputTensor(0).shape,
      0.0,
    );
    _interpreter!.run(zeroInput, outputTensor);
  }

  AIPrediction _parsePrediction(List<double> rawValues) {
    if (rawValues.isEmpty) {
      return const AIPrediction(
        label: 'unknown',
        confidence: 0.0,
        distressConfidence: 0.0,
        probabilities: <double>[],
      );
    }

    final classCount = math.min(_classes.length, rawValues.length);
    final selectedValues = rawValues.take(classCount).toList();
    final probabilities = _looksLikeProbabilities(selectedValues)
        ? selectedValues
        : _softmax(selectedValues);

    var bestIndex = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[bestIndex]) bestIndex = i;
    }

    double distressValue = probabilities[0];

    return AIPrediction(
      label: _classes[bestIndex],
      confidence: probabilities[bestIndex],
      distressConfidence: distressValue,
      probabilities: probabilities,
    );
  }

  bool _looksLikeProbabilities(List<double> values) {
    final sum = values.fold<double>(0.0, (total, value) => total + value);
    final allNormalized = values.every((value) => value >= 0.0 && value <= 1.0);
    return allNormalized && sum > 0.90 && sum < 1.10;
  }

  List<double> _softmax(List<double> logits) {
    final maxLogit = logits.reduce(math.max);
    final exps = logits.map((value) => math.exp(value - maxLogit)).toList();
    final sum = exps.fold<double>(0.0, (total, value) => total + value);
    return exps.map((value) => value / sum).toList();
  }

  Future<void> simulateDistressDetection({double confidence = 0.98}) async {
    final normalizedConfidence = confidence.clamp(0.0, 1.0).toDouble();

    aiConfidence.value = normalizedConfidence;
    aiPrediction.value = 'distress';
    aiStatus.value = 'Demo distress detected';

    // FIXED: Changed string label to 'distress' to match Controller validation mapping rules perfectly
    await _notifyDistressDetected(
      AIDistressEvent(
        confidence: normalizedConfidence,
        label: 'distress',
        isSimulated: true,
      ),
    );
  }

  Future<void> _notifyDistressDetected(AIDistressEvent event) async {
    if (_isTriggering || isRecording.value) return;

    _isTriggering = true;
    try {
      await _onDistressDetected?.call(event);
    } finally {
      _isTriggering = false;
    }
  }

  dynamic _buildFilledTensor(List<int> shape, double value) {
    if (shape.isEmpty) return value;
    if (shape.length == 1) return List<double>.filled(shape.first, value);

    final remainingShape = shape.sublist(1);
    return List<dynamic>.generate(
      shape.first,
      (_) => _buildFilledTensor(remainingShape, value),
    );
  }

  List<double> _flattenNumericValues(dynamic value) {
    if (value is num) return <double>[value.toDouble()];
    if (value is List) return value.expand(_flattenNumericValues).toList();
    return <double>[];
  }

  Future<void> dispose() async {
    await stopMonitoring();
    await _audioRecorder.dispose();
    _interpreter?.close();
    _interpreter = null;
    _isModelLoaded = false;
    aiModelReady.value = false;
    aiActive.value = false;
  }
}
