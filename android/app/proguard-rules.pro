# Release-build (R8) rules. Flutter's Gradle plugin applies this file automatically.

# tflite_flutter's optional GPU delegate refers to classes from the separate
# tensorflow-lite-gpu-api artifact, which the app doesn't include or use
# (inference runs on the CPU). Without this, R8 fails the release build.
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
