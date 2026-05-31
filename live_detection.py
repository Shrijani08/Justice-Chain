import numpy as np
import tensorflow as tf
import librosa
import cv2
import pyaudio
import time
import threading
import hashlib
import wave
import subprocess
import os

from collections import deque
from datetime import datetime

# ==============================
# CONFIGURATION
# ==============================
MODEL_PATH = "justice_chain_model.h5"
CLASSES = ["distress", "happy", "normal"]

SAMPLE_RATE = 16000
CHUNK_DURATION = 2
CHANNELS = 1
FORMAT = pyaudio.paFloat32
CHUNK_SIZE = int(SAMPLE_RATE * CHUNK_DURATION)

RECORD_CHUNK_SECONDS = 5
PREBUFFER_SECONDS = 6
TOTAL_RECORD_DURATION = 30

# ==============================
# LOAD MODEL
# ==============================
print("🧠 Loading Justice-Chain Model...")
model = tf.keras.models.load_model(MODEL_PATH)

# ==============================
# PREPROCESS FUNCTION
# ==============================
def preprocess_live_audio(audio_data):

    if np.max(np.abs(audio_data)) < 0.01:
        return None

    audio_data = librosa.effects.preemphasis(audio_data)

    rms = np.sqrt(np.mean(audio_data**2))

    if rms > 1e-6:
        audio_data = audio_data * (0.1 / rms)

    S = librosa.feature.melspectrogram(
        y=audio_data,
        sr=SAMPLE_RATE,
        n_mels=128,
        hop_length=512
    )

    S_DB = librosa.power_to_db(S, ref=np.max)

    S_DB = cv2.resize(S_DB, (128, 128))

    denom = (S_DB.max() - S_DB.min()) + 1e-8
    S_DB = (S_DB - S_DB.min()) / denom

    return S_DB[np.newaxis, ..., np.newaxis]

# ==============================
# MERGE FUNCTIONS
# ==============================
def verify_hash(file_path, expected_hash):

    with open(file_path, "rb") as f:
        current_hash = hashlib.sha256(f.read()).hexdigest()

    return current_hash == expected_hash


def merge_with_timestamp(video, audio, output):

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

    command = [
        "ffmpeg",
        "-y",
        "-i", video,
        "-i", audio,
        "-vf",
        f"drawtext=text='{timestamp}':x=10:y=H-th-10:fontsize=24:fontcolor=white",
        "-c:v", "libx264",
        "-c:a", "aac",
        output
    ]

    result = subprocess.run(command)

    if result.returncode == 0:
        print(f"✅ Merged successfully: {output}")
    else:
        print(f"❌ Merge failed: {output}")


def auto_merge_all_chunks(hash_dict):

    files = os.listdir()

    video_files = sorted([f for f in files if f.endswith(".avi")])

    merged_outputs = []

    for video in video_files:

        chunk_id = video.split("_")[1].split(".")[0]

        audio = f"chunk_{chunk_id}.wav"

        if audio in files:

            if video in hash_dict:

                if not verify_hash(video, hash_dict[video]):
                    print(f"❌ Hash mismatch: {video}")
                    continue

            output = f"merged_{chunk_id}.mp4"

            merge_with_timestamp(video, audio, output)

            merged_outputs.append(output)

    return merged_outputs


def combine_final_video(merged_files):

    with open("file_list.txt", "w") as f:

        for file in merged_files:
            f.write(f"file '{file}'\n")

    command = [
        "ffmpeg",
        "-f", "concat",
        "-safe", "0",
        "-i", "file_list.txt",
        "-c", "copy",
        "final_evidence.mp4"
    ]

    subprocess.run(command)

    print("🎥 FINAL EVIDENCE CREATED")

# ==============================
# EVIDENCE MANAGER
# ==============================
class EvidenceManager:

    def __init__(self):

        self.recording = False
        self.lock = threading.Lock()

        # stores hashes
        self.hash_dict = {}

    def start_capture(self, prebuffer_audio):

        with self.lock:

            if self.recording:
                return

            self.recording = True

        threading.Thread(
            target=self._record_loop,
            args=(prebuffer_audio,)
        ).start()

    def _record_loop(self, prebuffer_audio):

        print("🎥 Evidence recording STARTED")

        cap = cv2.VideoCapture(0)

        chunk_id = 0

        # ==============================
        # SAVE PREBUFFER
        # ==============================
        for audio_chunk in prebuffer_audio:

            self._save_audio_chunk(
                audio_chunk,
                f"prebuffer_{chunk_id}.wav"
            )

            chunk_id += 1

        start_time = time.time()

        while time.time() - start_time < TOTAL_RECORD_DURATION:

            video_filename = f"chunk_{chunk_id}.avi"
            audio_filename = f"chunk_{chunk_id}.wav"

            self._record_chunk(
                cap,
                video_filename,
                audio_filename
            )

            # ==============================
            # HASH VIDEO
            # ==============================
            file_hash = self.hash_file(video_filename)

            self.hash_dict[video_filename] = file_hash

            print(f"🔒 Chunk {chunk_id} Hash:")
            print(file_hash)

            chunk_id += 1

        cap.release()

        print("🎬 Auto-merging evidence...")

        merged = auto_merge_all_chunks(self.hash_dict)

        combine_final_video(merged)

        with self.lock:
            self.recording = False

        print("🛑 Evidence recording STOPPED")

    def _record_chunk(self, cap, video_file, audio_file):

        fourcc = cv2.VideoWriter_fourcc(*'XVID')

        out = cv2.VideoWriter(
            video_file,
            fourcc,
            20.0,
            (640, 480)
        )

        start = time.time()

        while time.time() - start < RECORD_CHUNK_SECONDS:

            ret, frame = cap.read()

            if ret:
                out.write(frame)

        out.release()

        self._record_audio(
            audio_file,
            RECORD_CHUNK_SECONDS
        )

    def _record_audio(self, filename, duration):

        p = pyaudio.PyAudio()

        stream = p.open(
            format=FORMAT,
            channels=1,
            rate=SAMPLE_RATE,
            input=True,
            frames_per_buffer=1024
        )

        frames = []

        for _ in range(int(SAMPLE_RATE / 1024 * duration)):

            data = stream.read(
                1024,
                exception_on_overflow=False
            )

            frames.append(data)

        stream.stop_stream()
        stream.close()

        p.terminate()

        wf = wave.open(filename, 'wb')

        wf.setnchannels(1)

        wf.setsampwidth(
            p.get_sample_size(FORMAT)
        )

        wf.setframerate(SAMPLE_RATE)

        wf.writeframes(b''.join(frames))

        wf.close()

    def _save_audio_chunk(self, audio_data, filename):

        wf = wave.open(filename, 'wb')

        wf.setnchannels(1)

        wf.setsampwidth(4)

        wf.setframerate(SAMPLE_RATE)

        wf.writeframes(audio_data.tobytes())

        wf.close()

    def hash_file(self, filename):

        with open(filename, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()

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

# ==============================
# INIT
# ==============================
manager = EvidenceManager()

prebuffer = deque(
    maxlen=int(PREBUFFER_SECONDS / CHUNK_DURATION)
)

print("\n🚀 LISTENING...")

# ==============================
# REAL-TIME LOOP
# ==============================
try:

    while True:

        data = stream.read(
            CHUNK_SIZE,
            exception_on_overflow=False
        )

        audio_chunk = np.frombuffer(
            data,
            dtype=np.float32
        )

        prebuffer.append(audio_chunk.copy())

        processed_input = preprocess_live_audio(audio_chunk)

        if processed_input is None:
            print("🔇 Silence...")
            continue

        prediction = model.predict(
            processed_input,
            verbose=0
        )

        class_idx = np.argmax(prediction)

        confidence = prediction[0][class_idx] * 100

        result = CLASSES[class_idx]

        if result == "distress" and confidence > 80:

            print(f"🚨 DISTRESS DETECTED ({confidence:.2f}%)")

            manager.start_capture(list(prebuffer))

        else:

            print(f"✅ {result} ({confidence:.2f}%)")

        time.sleep(0.2)

except KeyboardInterrupt:

    print("\n🛑 Stopping Justice-Chain...")

finally:

    stream.stop_stream()
    stream.close()

    p.terminate()