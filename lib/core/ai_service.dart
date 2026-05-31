import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../logic/safety_signals.dart';
import 'audio_preprocessor.dart';

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

  static const String _modelAssetPath =
      'assets/models/justice_chain_model.tflite';
  static const List<String> _classes = ['distress', 'happy', 'normal'];
  static const double distressThreshold = 0.85;
  static const int _sampleRate = AudioPreprocessor.sampleRate;
  static const int _windowSampleCount = AudioPreprocessor.chunkSampleCount;
  static const int _inferenceStrideSamples = _sampleRate;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final ListQueue<double> _rollingSamples = ListQueue<double>();
  
  // Temporal validation sliding queue to filter out sporadic environment spikes
  final ListQueue<double> _recentConfidences = ListQueue<double>();
  static const int _requiredConsensusFrames = 3;

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
    aiStatus.value = 'Loading AI distress model...';

    try {
      final options = InterpreterOptions()..threads = 2;

      _interpreter = await Interpreter.fromAsset(
        _modelAssetPath,
        options: options,
      );
      _interpreter!.resizeInputTensor(0, const [1, 128, 128, 1]);
      _interpreter!.allocateTensors();
      _runModelSelfTest();

      _isModelLoaded = true;
      aiModelReady.value = true;
      aiStatus.value = 'AI model ready';
      aiConfidence.value = 0.0;
      aiPrediction.value = 'none';
      _lastModelError = null;

      developer.log(
        'TFLite model loaded from $_modelAssetPath',
        name: 'JusticeChain.AI',
      );
      debugPrint('JusticeChain.AI: TFLite model loaded from $_modelAssetPath');
      developer.log(
        'Input tensor shape: ${_interpreter?.getInputTensor(0).shape}',
        name: 'JusticeChain.AI',
      );
      developer.log(
        'Output tensor shape: ${_interpreter?.getOutputTensor(0).shape}',
        name: 'JusticeChain.AI',
      );
    } catch (error, stackTrace) {
      _isModelLoaded = false;
      aiModelReady.value = false;
      aiActive.value = false;
      _lastModelError = error.toString().split('\n').first;
      aiStatus.value = 'AI model load failed: $_lastModelError';

      developer.log(
        'Failed to initialize TFLite interpreter: $error',
        name: 'JusticeChain.AI',
        error: error,
        stackTrace: stackTrace,
      );
      debugPrint('JusticeChain.AI: model load failed: $error');
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
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        streamBufferSize: 2048,
      ),
    );

    _rollingSamples.clear();
    _recentConfidences.clear();
    _samplesSinceLastInference = 0;
    _isMonitoring = true;
    aiActive.value = true;
    aiDistressDetected.value = false;
    aiStatus.value = 'AI listening at 16 kHz';

    developer.log(
      'Microphone stream initialized: PCM16 mono, $_sampleRate Hz.',
      name: 'JusticeChain.AI',
    );
    debugPrint(
      'JusticeChain.AI: microphone stream initialized PCM16 mono $_sampleRate Hz',
    );

    _audioSubscription = stream.listen(
      _handlePcmBytes,
      onError: (Object error, StackTrace stackTrace) {
        aiStatus.value = 'AI microphone stream error';
        aiActive.value = false;
        developer.log(
          'Microphone stream error: $error',
          name: 'JusticeChain.AI',
          error: error,
          stackTrace: stackTrace,
        );
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
    _recentConfidences.clear();
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

    developer.log(
      'AI microphone monitoring paused for camera recording.',
      name: 'JusticeChain.AI',
    );
  }

  Future<void> resumeAfterRecording() async {
    if (!_isPausedForRecording) return;

    _isPausedForRecording = false;
    aiDistressDetected.value = false;
    await startMonitoring();
  }

  void _handlePcmBytes(Uint8List bytes) {
    final samples = _pcm16BytesToSamples(bytes);
    if (samples.isEmpty || !_isMonitoring || isRecording.value) return;

    for (final sample in samples) {
      _rollingSamples.addLast(sample);
      while (_rollingSamples.length > _windowSampleCount) {
        _rollingSamples.removeFirst();
      }
    }

    _samplesSinceLastInference += samples.length;

    developer.log(
      'Audio chunk captured: ${samples.length} samples, '
      'rolling=${_rollingSamples.length}/$_windowSampleCount.',
      name: 'JusticeChain.AI',
    );

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
    aiStatus.value = 'AI preprocessing audio window';

    try {
      final processed = await compute(preprocessAudioChunk, samples);
      final inputTensor = processed['tensor'];
      final rms = (processed['rms'] as num?)?.toDouble() ?? 0.0;
      final isSilent = processed['silent'] == true;

      developer.log(
        'Preprocessing completed. RMS=${rms.toStringAsFixed(5)}, silent=$isSilent.',
        name: 'JusticeChain.AI',
      );
      debugPrint(
        'JusticeChain.AI: preprocessing completed rms=${rms.toStringAsFixed(5)} silent=$isSilent',
      );

      if (isSilent) {
        aiStatus.value = 'AI listening: silence filtered';
        aiPrediction.value = 'silence';
        aiConfidence.value = 0.0;
        _recentConfidences.clear(); 
        return;
      }

      final prediction = evaluateDistressSignals(inputTensor);
      aiPrediction.value = prediction.label;
      aiConfidence.value = prediction.distressConfidence;

      _recentConfidences.addLast(prediction.distressConfidence);
      while (_recentConfidences.length > _requiredConsensusFrames) {
        _recentConfidences.removeFirst();
      }

      final percent = (prediction.distressConfidence * 100).toStringAsFixed(0);
      aiStatus.value = 'AI prediction: ${prediction.label} ($percent%)';

      developer.log(
        'Inference completed. class=${prediction.label}, '
        'distressConfidence=${prediction.distressConfidence.toStringAsFixed(3)}.',
        name: 'JusticeChain.AI',
      );

      bool meetsConsensus = _recentConfidences.length == _requiredConsensusFrames &&
          _recentConfidences.every((c) => c >= distressThreshold);

      if (meetsConsensus) {
        aiDistressDetected.value = true;
        _recentConfidences.clear(); 
        
        developer.log(
          '🔥 CONSENSUS TRIGGERED: Distress confirmed across sequential frames.',
          name: 'JusticeChain.AI',
        );

        await _notifyDistressDetected(
          AIDistressEvent(
            confidence: prediction.distressConfidence,
            label: prediction.label,
            isSimulated: false,
          ),
        );
      } else {
        aiDistressDetected.value = false;
      }
    } catch (error, stackTrace) {
      aiStatus.value = 'AI inference pipeline error';
      developer.log(
        'Realtime AI pipeline failed: $error',
        name: 'JusticeChain.AI',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isPreprocessing = false;
    }
  }

  AIPrediction evaluateDistressSignals(dynamic inputTensor) {
    if (!_isModelLoaded || _interpreter == null) {
      aiStatus.value = 'AI inference skipped: model not ready';
      return const AIPrediction(
        label: 'unavailable',
        confidence: 0.0,
        distressConfidence: 0.0,
        probabilities: <double>[],
      );
    }

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final outputTensor = _buildFilledTensor(outputShape, 0.0);

    _interpreter!.run(inputTensor, outputTensor);

    final rawValues = _flattenNumericValues(outputTensor);
    final prediction = _parsePrediction(rawValues);

    developer.log(
      'Raw model output: ${rawValues.map((v) => v.toStringAsFixed(4)).toList()}',
      name: 'JusticeChain.AI',
    );

    return prediction;
  }

  void _runModelSelfTest() {
    final zeroInput = [
      List<List<List<double>>>.generate(
        128,
        (_) => List<List<double>>.generate(128, (_) => [0.0]),
      ),
    ];
    final outputTensor = _buildFilledTensor(
      _interpreter!.getOutputTensor(0).shape,
      0.0,
    );

    _interpreter!.run(zeroInput, outputTensor);

    developer.log(
      'TFLite self-test passed with output '
      '${_flattenNumericValues(outputTensor).map((v) => v.toStringAsFixed(4)).toList()}.',
      name: 'JusticeChain.AI',
    );
    debugPrint('JusticeChain.AI: TFLite self-test passed');
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

    if (rawValues.length == 1) {
      final value = rawValues.first;
      final distressConfidence = value >= 0.0 && value <= 1.0
          ? value
          : 1.0 / (1.0 + math.exp(-value));
      return AIPrediction(
        label: distressConfidence >= distressThreshold ? 'distress' : 'normal',
        confidence: distressConfidence >= distressThreshold
            ? distressConfidence
            : 1.0 - distressConfidence,
        distressConfidence: distressConfidence,
        probabilities: <double>[distressConfidence],
      );
    }

    final classCount = math.min(_classes.length, rawValues.length);
    final selectedValues = rawValues.take(classCount).toList();
    final probabilities = _looksLikeProbabilities(selectedValues)
        ? selectedValues
        : _softmax(selectedValues);

    var bestIndex = 0;
    for (var i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[bestIndex]) {
        bestIndex = i;
      }
    }

    return AIPrediction(
      label: _classes[bestIndex],
      confidence: probabilities[bestIndex],
      distressConfidence: probabilities[0],
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
    aiDistressDetected.value = true;
    aiStatus.value = 'Demo distress detected';

    developer.log(
      'Demo AI distress trigger fired at confidence '
      '${normalizedConfidence.toStringAsFixed(3)}.',
      name: 'JusticeChain.AI',
    );

    await _notifyDistressDetected(
      AIDistressEvent(
        confidence: normalizedConfidence,
        label: 'demo_distress',
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
    if (shape.length == 1) {
      return List<double>.filled(shape.first, value);
    }

    final remainingShape = shape.sublist(1);
    return List<dynamic>.generate(
      shape.first,
      (_) => _buildFilledTensor(remainingShape, value),
    );
  }

  List<double> _flattenNumericValues(dynamic value) {
    if (value is num) return <double>[value.toDouble()];
    if (value is List) {
      return value.expand(_flattenNumericValues).toList();
    }
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