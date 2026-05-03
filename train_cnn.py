import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models
import matplotlib.pyplot as plt

# ==============================
# 1. GPU CHECK
# ==============================
gpus = tf.config.list_physical_devices('GPU')

print("Num GPUs Available:", len(gpus))

if gpus:
    try:
        for gpu in gpus:
            tf.config.experimental.set_memory_growth(gpu, True)
        print(f"🚀 Using GPU: {gpus[0].name}")
    except RuntimeError as e:
        print(e)
else:
    print("⚠️ GPU not found. Training will run on CPU.")

# ==============================
# 2. LOAD DATA
# ==============================
print("\n📦 Loading dataset...")

X_train = np.load("X_train.npy")
X_val   = np.load("X_val.npy")
X_test  = np.load("X_test.npy")

y_train = np.load("y_train.npy")
y_val   = np.load("y_val.npy")
y_test  = np.load("y_test.npy")

print(f"Training: {X_train.shape}")
print(f"Validation: {X_val.shape}")
print(f"Test: {X_test.shape}")

# ==============================
# 3. MODEL
# ==============================
def build_model(input_shape, num_classes):
    model = models.Sequential([
        layers.Conv2D(32, (3,3), activation='relu', input_shape=input_shape),
        layers.MaxPooling2D(2,2),

        layers.Conv2D(64, (3,3), activation='relu'),
        layers.MaxPooling2D(2,2),

        layers.Conv2D(128, (3,3), activation='relu'),
        layers.MaxPooling2D(2,2),

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

input_shape = (128, 128, 1)
num_classes = y_train.shape[1]

model = build_model(input_shape, num_classes)

model.summary()

# ==============================
# 4. TRAIN
# ==============================
print("\n🧠 Training started...")

history = model.fit(
    X_train, y_train,
    epochs=20,
    batch_size=64,
    validation_data=(X_val, y_val)
)

# ==============================
# 5. EVALUATE
# ==============================
test_loss, test_acc = model.evaluate(X_test, y_test)

print(f"\n🎯 Test Accuracy: {test_acc:.4f}")

# ==============================
# 6. SAVE MODEL
# ==============================
model.save("justice_chain_model.h5")
print("💾 Model saved as justice_chain_model.h5")

# ==============================
# 7. PLOT (optional)
# ==============================
plt.plot(history.history['accuracy'], label='train')
plt.plot(history.history['val_accuracy'], label='val')
plt.legend()
plt.title("Model Accuracy")
plt.show()