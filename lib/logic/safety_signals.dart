import 'package:signals_flutter/signals_flutter.dart';

// Signals act as reactive variables
final appStatus = signal<String>("Initializing...");
final isRecording = signal<bool>(false);
final cameraReady = signal<bool>(false);
final aiStatus = signal<String>("AI model not initialized");
final aiConfidence = signal<double>(0.0);
final aiModelReady = signal<bool>(false);
final aiActive = signal<bool>(false);
final aiPrediction = signal<String>("none");
final aiDistressDetected = signal<bool>(false);