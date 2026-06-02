import os
os.environ['TF_ENABLE_ONEDNN_OPTS'] = '0'
os.environ['CUDA_VISIBLE_DEVICES'] = '-1'  # force CPU only for conversion

import tensorflow as tf

print("📦 Loading the trained Keras model...")
model = tf.keras.models.load_model("justice_chain_1d_model")
model.summary()

print("🔄 Converting architecture to memory-optimized TFLite binary...")
converter = tf.lite.TFLiteConverter.from_keras_model(model)

# Apply standard optimizations to minimize model size
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.target_spec.supported_ops = [
    tf.lite.OpsSet.TFLITE_BUILTINS,
    tf.lite.OpsSet.SELECT_TF_OPS
]
converter.allow_custom_ops = True  # needed for some Conv1D ops in TFLite

tflite_model = converter.convert()

# Save the binary
output_filename = "distress_model.tflite"
with open(output_filename, "wb") as f:
    f.write(tflite_model)

print(f"✅ Converted successfully!")
print(f"📁 File saved as: {output_filename}")
print(f"📏 Model size: {len(tflite_model) / 1024:.1f} KB")