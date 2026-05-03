import 'package:signals_flutter/signals_flutter.dart';

// Signals act as reactive variables
final appStatus = signal<String>("Initializing...");
final isRecording = signal<bool>(false);
final cameraReady = signal<bool>(false);