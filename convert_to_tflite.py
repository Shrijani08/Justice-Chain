import os

import tensorflow as tf


model_file = "justice_chain_model.h5"
if not os.path.exists(model_file):
    raise FileNotFoundError(f"Missing base architecture file: {model_file}")

model = tf.keras.models.load_model(model_file, compile=False)

converter = tf.lite.TFLiteConverter.from_keras_model(model)

# Keep the app model on standard TFLite builtins only. The Flutter app uses
# tflite_flutter 0.11.0, which bundles Android TensorFlow Lite 2.11. A pure
# float32 conversion avoids newer dynamic-range quantized op versions that can
# load in desktop TensorFlow but fail on the mobile runtime.
converter.target_spec.supported_ops = [
    tf.lite.OpsSet.TFLITE_BUILTINS,
]

tflite_model = converter.convert()

output_path = os.path.join("assets", "models", "justice_chain_model.tflite")
with open(output_path, "wb") as f:
    f.write(tflite_model)

print("Clean Android-compatible float32 TFLite asset generated successfully!")
