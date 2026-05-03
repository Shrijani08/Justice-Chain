import os
import librosa
import numpy as np
import cv2

# Paths
INPUT_BASE = r"E:\audio_dataset_project\processed_dataset"
OUTPUT_BASE = r"E:\audio_dataset_project\spectrogram_dataset"
CLASSES = ["distress", "happy", "normal"]

# Mel-Spectrogram Hyperparameters
N_MELS = 128
HOP_LENGTH = 512
SAMPLE_RATE = 16000

def generate_spectrograms():
    os.makedirs(OUTPUT_BASE, exist_ok=True)
    
    for cls in CLASSES:
        input_folder = os.path.join(INPUT_BASE, cls)
        output_folder = os.path.join(OUTPUT_BASE, cls)
        os.makedirs(output_folder, exist_ok=True)
        
        print(f"🖼️ Generating fixed-dim spectrograms for: {cls}")
        
        for file in os.listdir(input_folder):
            if not file.endswith(".wav"):
                continue
                
            file_path = os.path.join(input_folder, file)
            save_path = os.path.join(output_folder, file.replace(".wav", ".npy"))

            # --- OPTIONAL IMPROVEMENT 1: SKIP CORRUPT ---
            if os.path.getsize(file_path) < 1000:
                print(f"⚠️ Skipping empty/corrupt file: {file}")
                continue

            try:
                y, sr = librosa.load(file_path, sr=SAMPLE_RATE)
                S = librosa.feature.melspectrogram(y=y, sr=sr, n_mels=N_MELS, hop_length=HOP_LENGTH)
                S_DB = librosa.power_to_db(S, ref=np.max)
                S_DB = cv2.resize(S_DB, (128, 128))
                
                # Normalize 0 to 1
                denom = (S_DB.max() - S_DB.min()) + 1e-8
                S_DB = (S_DB - S_DB.min()) / denom
                
                # --- OPTIONAL IMPROVEMENT 2: ADD CHANNEL DIM ---
                # Converts (128, 128) -> (128, 128, 1) right now so training is easier
                S_DB = S_DB[..., np.newaxis]
                
                np.save(save_path, S_DB.astype(np.float32))
                
            except Exception as e:
                print(f"❌ Error on {file}: {e}")

    print("🔥 DATASET READY FOR CNN TRAINING!")

if __name__ == "__main__":
    generate_spectrograms()