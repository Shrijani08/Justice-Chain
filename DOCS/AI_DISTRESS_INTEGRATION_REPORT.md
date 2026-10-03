# Justice Chain AI Distress Detection Integration Report

## Overview

This update adds a proof-of-concept AI distress detection flow to the existing Flutter app. The goal is to support Review-2 demo requirements by loading the TensorFlow Lite model, showing AI readiness and confidence in the UI, and allowing a debug button to simulate a distress event that automatically starts emergency video and audio recording.

The implementation keeps the existing recording, SHA-256 evidence hashing, and Hive vault storage flow intact.

## Files Updated

### `lib/core/ai_service.dart`

Created a dedicated `AIService` class that:

- Loads `assets/models/justice_chain_model.tflite` using `tflite_flutter`.
- Tracks whether the model is ready.
- Maintains AI status and confidence values through shared signals.
- Starts a 2-second monitoring timer for future microphone audio chunks.
- Includes placeholder logic for future live audio preprocessing and inference.
- Provides `simulateDistressDetection()` for demo/testing.
- Calls a registered distress callback when distress is detected or simulated.

Live microphone preprocessing is not implemented yet. The placeholder section is documented inside `AIService` for future integration of PCM capture, mel-spectrogram conversion, and real inference.

### `lib/core/emergency_controller.dart`

Updated the controller so the AI system can trigger the existing emergency recording flow.

Important behavior:

- `startBackgroundMonitoring()` starts the AI monitor and registers the distress callback.
- `simulateAIDistressDetection()` triggers the demo AI distress event.
- When AI distress is detected, the controller calls `startRecording()`.
- Recording is guarded so duplicate triggers do not start multiple recordings.

### `lib/logic/safety_signals.dart`

Added AI UI state signals:

- `aiStatus`
- `aiConfidence`
- `aiModelReady`

These are watched by the home screen so the UI updates automatically.

### `lib/presentation/home_screen.dart`

Updated the home screen to:

- Start AI monitoring after camera initialization.
- Show AI model status.
- Show AI confidence as a progress indicator.
- Add a temporary debug button: `Debug: Simulate AI Distress`.
- Route manual and AI-triggered recordings through `EmergencyController`.
- Preserve evidence saving, SHA-256 hashing, and Hive vault storage.

### `lib/main.dart`

Added model warm-loading at app startup:

```dart
await AIService.instance.initModel();
```

This allows the app to report AI readiness early. The actual distress callback is registered later when the camera is ready.

## How The Demo Flow Works

1. App starts and initializes Hive/logger services.
2. The TFLite model is loaded from `assets/models/justice_chain_model.tflite`.
3. The home screen requests camera and microphone permissions.
4. After the camera is initialized, AI monitoring starts.
5. The UI shows:
   - App status
   - Camera/recording readiness
   - AI status
   - AI confidence percentage
6. Pressing `Debug: Simulate AI Distress` calls `AIService.simulateDistressDetection()`.
7. The AI service reports a high-confidence distress event.
8. `EmergencyController` receives the event and starts video+audio recording.
9. Pressing `STOP RECORDING` saves the evidence, hashes it with SHA-256, and stores metadata in Hive.

## How To Run

From the project root:

```powershell
cd "E:\justice chain 2\Justice-Chain"
flutter pub get
flutter run
```

On Android, make sure a physical device or emulator is connected:

```powershell
flutter devices
flutter run -d <device-id>
```

## How To Test The AI Demo Trigger

1. Launch the app.
2. Allow camera and microphone permissions.
3. Wait until the screen shows that the system is ready.
4. Press `Debug: Simulate AI Distress`.
5. Confirm that recording starts automatically.
6. Press `STOP RECORDING`.
7. The app saves the video evidence and generates a SHA-256 fingerprint.
8. Press `Debug: Print Vault Contents` to print stored vault metadata to the console.

## Validation Performed

The updated Dart files were analyzed successfully:

```powershell
dart analyze lib\core\ai_service.dart lib\core\emergency_controller.dart lib\presentation\home_screen.dart lib\main.dart lib\logic\safety_signals.dart
```

Result:

```text
No issues found!
```

Android debug build was also run. The APK was generated at:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Gradle printed warnings from third-party Android dependencies, but the debug APK was produced successfully.

## Future Work

The next AI implementation step is to replace the placeholder monitoring logic with real audio preprocessing:

1. Capture microphone audio in 2-second chunks.
2. Convert PCM audio into the same spectrogram format used during model training.
3. Pass the spectrogram tensor into the TFLite interpreter.
4. Detect screams or emergency keywords using the model output.
5. Tune the distress confidence threshold based on real-world testing.

## Summary

The app now has a working Review-2 proof-of-concept AI trigger path. The TFLite model loads, AI status and confidence appear in the UI, and a simulated distress event can automatically start emergency video+audio recording through the existing secure evidence pipeline.
