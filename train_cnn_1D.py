import os
os.environ['TF_ENABLE_ONEDNN_OPTS'] = '0'
os.environ['TF_GPU_ALLOCATOR'] = 'cuda_malloc_async'

import numpy as np
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers, models


# ==============================
# 1. DIRECTML HARDWARE ACCELERATION CHECK
# ===============================
print("🔎 Scanning hardware architecture for DirectML devices...")
visible_gpus = tf.config.list_physical_devices('GPU')

if visible_gpus:
    print(f"🚀 SUCCESS! DirectML connected to GPU: {visible_gpus}")
else:
    print("⚠️ DirectML did not bind to your GPU. Defaulting back to CPU.")


# ==============================
# 2. LOAD 1D AUDIO DATA
# ==============================
print("\n📦 Loading 1D dataset arrays...")
X_train = np.load("X_train_1d.npy")
X_val   = np.load("X_val_1d.npy")
X_test  = np.load("X_test_1d.npy")

y_train = np.load("y_train_1d.npy")
y_val   = np.load("y_val_1d.npy")
y_test  = np.load("y_test_1d.npy")

# ==============================
# 3. BUILD tf.data PIPELINES
# ==============================
print("\n⚙️ Building memory-efficient data pipelines...")
BATCH_SIZE = 8

with tf.device('/CPU:0'):  # keep data on CPU, only send batches to GPU
    train_dataset = tf.data.Dataset.from_tensor_slices((X_train, y_train)).shuffle(500).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)
    val_dataset   = tf.data.Dataset.from_tensor_slices((X_val, y_val)).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)
    test_dataset  = tf.data.Dataset.from_tensor_slices((X_test, y_test)).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)

# ==============================
# 4. 1D CNN MODEL ARCHITECTURE
# ==============================
def build_1d_model(input_shape, num_classes):
    model = models.Sequential([
        layers.Conv1D(16, kernel_size=64, strides=4, activation='relu', input_shape=input_shape),
        layers.MaxPooling1D(pool_size=4),
        layers.Dropout(0.2),

        layers.Conv1D(32, kernel_size=32, strides=2, activation='relu'),
        layers.MaxPooling1D(pool_size=4),
        layers.Dropout(0.2),

        layers.Conv1D(64, kernel_size=16, strides=1, activation='relu'),
        layers.MaxPooling1D(pool_size=4),
        layers.Dropout(0.3),

        layers.Flatten(),
        layers.Dense(128, activation='relu'),
        layers.Dropout(0.5),
        layers.Dense(num_classes, activation='softmax')
    ])

    model.compile(
        optimizer='adam',
        loss='categorical_crossentropy',
        metrics=['accuracy']
    )
    return model

input_shape = (32000, 1)  # 2 seconds of raw audio
num_classes = y_train.shape[1]

model = build_1d_model(input_shape, num_classes)
model.summary()

# ==============================
# 5. TRAINING
# ==============================
print("\n🧠 Training 1D CNN model on your RTX 4060 GPU...")

checkpoint_cb = tf.keras.callbacks.ModelCheckpoint(
    filepath="justice_chain_1d_checkpoint",
    save_best_only=True,
    monitor="val_accuracy",
    mode="max",
    verbose=1
)

history = model.fit(
    train_dataset,
    epochs=25,
    validation_data=val_dataset,
    callbacks=[checkpoint_cb]
)

# ==============================
# 6. EVALUATION
# ==============================
test_loss, test_acc = model.evaluate(test_dataset)
print(f"\n🎯 1D CNN Test Accuracy: {test_acc:.4f}")

model.save("justice_chain_1d_model")
print("💾 Saved Keras model as justice_chain_1d_model")