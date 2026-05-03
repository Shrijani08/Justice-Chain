import os
import librosa
import soundfile as sf
import numpy as np
import hashlib

# --- CONFIGURATION ---
INPUT_BASE = r"E:\audio_dataset_project\final_dataset"
OUTPUT_BASE = r"E:\audio_dataset_project\processed_dataset"
TARGET_DURATION = 2  # seconds
SAMPLE_RATE = 16000
TARGET_LENGTH = TARGET_DURATION * SAMPLE_RATE
CLASSES = ["distress", "happy", "normal"]

def generate_sha256(file_path):
    """Generates a SHA-256 hash to ensure a digital chain of custody."""
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def preprocess_audio():
    os.makedirs(OUTPUT_BASE, exist_ok=True)
    
    for cls in CLASSES:
        input_path = os.path.join(INPUT_BASE, cls)
        output_path = os.path.join(OUTPUT_BASE, cls)
        os.makedirs(output_path, exist_ok=True)

        for file in os.listdir(input_path):
            if not file.lower().endswith(".wav"):
                continue

            file_path = os.path.join(input_path, file)
            output_file = os.path.join(output_path, file)

            try:
                # 1. Load & Resample (Forensic Standard)
                audio, _ = librosa.load(file_path, sr=SAMPLE_RATE)

                # 2. Pre-Emphasis (Highlight Distress Harmonics)
                # Boosts high frequencies where screams and 'H'/'P' phonemes live
                audio = librosa.effects.preemphasis(audio)

                # 3. Adaptive Trimming (Remove Silence)
                # We use a 40dB threshold to catch quiet 'help' whispers
                trimmed_audio, _ = librosa.effects.trim(audio, top_db=40)

                # 4. Safety Check (Preserve Low-Energy Signals)
                # If trimming removed >50%, we revert to avoid losing evidence
                if len(trimmed_audio) < 0.5 * TARGET_LENGTH:
                    audio = audio
                else:
                    audio = trimmed_audio

                # 5. Segment Selection (Sliding Window for the 'Event')
                if len(audio) > TARGET_LENGTH:
                    max_energy = 0
                    best_start = 0
                    step = int(SAMPLE_RATE * 0.1) # 0.1s step for precision
                    
                    for i in range(0, len(audio) - TARGET_LENGTH, step):
                        window = audio[i:i + TARGET_LENGTH]
                        energy = np.sum(window**2)
                        if energy > max_energy:
                            max_energy = energy
                            best_start = i
                    audio = audio[best_start:best_start + TARGET_LENGTH]
                else:
                    # 6. Reflective Padding (Acoustic Continuity)
                    # We 'reflect' the sound instead of using silent zeros
                    audio = librosa.util.fix_length(audio, size=TARGET_LENGTH, mode='reflect')

                # 7. RMS Normalization (Consistent Power)
                rms = np.sqrt(np.mean(audio**2))
                if rms > 1e-6:
                    audio = audio * (0.1 / rms)

                # 8. Save & Hash (Chain of Custody)
                sf.write(output_file, audio, SAMPLE_RATE, subtype='PCM_16')
                file_hash = generate_sha256(output_file)
                
                # Note: In a full implementation, store file_hash in a CSV or DB
                
            except Exception as e:
                print(f"Error processing {file}: {e}")

    print("🔥 FORENSIC PREPROCESSING COMPLETE!")

if __name__ == "__main__":
    preprocess_audio()