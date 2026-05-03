import numpy as np
import tensorflow as tf
import librosa
import cv2
import pyaudio
import time

# ==============================
# CONFIGURATION
# ==============================
MODEL_PATH = "justice_chain_model.h5"
CLASSES = ["distress", "happy", "normal"]

SAMPLE_RATE = 16000
CHUNK_DURATION = 2  # seconds
CHANNELS = 1
FORMAT = pyaudio.paFloat32
CHUNK_SIZE = int(SAMPLE_RATE * CHUNK_DURATION)

# ==============================
# LOAD MODEL
# ==============================
print("🧠 Loading Justice-Chain Model...")
model = tf.keras.models.load_model(MODEL_PATH)

# ==============================
# PREPROCESS FUNCTION
# ==============================
def preprocess_live_audio(audio_data):
    # 🔇 Silence check
    if np.max(np.abs(audio_data)) < 0.01:
        return None

    # 🎯 Pre-emphasis
    audio_data = librosa.effects.preemphasis(audio_data)

    # 🎯 RMS normalization (VERY IMPORTANT)
    rms = np.sqrt(np.mean(audio_data**2))
    if rms > 1e-6:
        audio_data = audio_data * (0.1 / rms)

    # 🎯 Mel Spectrogram
    S = librosa.feature.melspectrogram(
        y=audio_data,
        sr=SAMPLE_RATE,
        n_mels=128,
        hop_length=512
    )

    # Convert to dB
    S_DB = librosa.power_to_db(S, ref=np.max)

    # Resize to (128,128)
    S_DB = cv2.resize(S_DB, (128, 128))

    # Normalize (0–1)
    denom = (S_DB.max() - S_DB.min()) + 1e-8
    S_DB = (S_DB - S_DB.min()) / denom

    # Add batch + channel dims
    return S_DB[np.newaxis, ..., np.newaxis]

# ==============================
# MICROPHONE SETUP
# ==============================
p = pyaudio.PyAudio()

stream = p.open(
    format=FORMAT,
    channels=CHANNELS,
    rate=SAMPLE_RATE,
    input=True,
    frames_per_buffer=CHUNK_SIZE
)

print("\n🚀 LISTENING... (Try shouting 'HELP' or screaming)")
print("Press Ctrl+C to stop.\n")

# ==============================
# REAL-TIME LOOP
# ==============================
try:
    while True:
        # 🎤 Read audio
        data = stream.read(CHUNK_SIZE, exception_on_overflow=False)
        audio_chunk = np.frombuffer(data, dtype=np.float32)

        # 🔄 Preprocess
        processed_input = preprocess_live_audio(audio_chunk)

        # Skip silence
        if processed_input is None:
            print("🔇 Silence...")
            time.sleep(0.2)
            continue

        # 🤖 Predict
        prediction = model.predict(processed_input, verbose=0)
        class_idx = np.argmax(prediction)
        confidence = prediction[0][class_idx] * 100

        result = CLASSES[class_idx]

        # 🚨 Decision logic
        if result == "distress" and confidence > 80:
            print(f"🚨 ALERT: DISTRESS DETECTED! ({confidence:.2f}%)")
        else:
            print(f"✅ Status: {result} ({confidence:.2f}%)")

        # ⏳ Prevent CPU overload
        time.sleep(0.2)

except KeyboardInterrupt:
    print("\n🛑 Stopping Justice-Chain...")

finally:
    stream.stop_stream()
    stream.close()
    p.terminate()