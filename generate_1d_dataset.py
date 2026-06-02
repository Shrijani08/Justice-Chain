import os
import librosa
import numpy as np
from tensorflow.keras.utils import to_categorical
from sklearn.model_selection import train_test_split

# --- CONFIGURATION ---
PROCESSED_BASE = r"E:\audio_dataset_project\processed_dataset"
CLASSES = ["distress", "happy", "normal"]
TARGET_LENGTH = 32000  # 2 seconds * 16000Hz

def load_1d_dataset():
    X = []
    y = []
    
    for class_idx, cls in enumerate(CLASSES):
        class_dir = os.path.join(PROCESSED_BASE, cls)
        print(f"📦 Loading 1D samples for class: {cls}...")
        
        for file in os.listdir(class_dir):
            if not file.lower().endswith(".wav"):
                continue
                
            file_path = os.path.join(class_dir, file)
            try:
                # Load processed audio (guaranteed to be 16kHz and 2s long by your script)
                audio, _ = librosa.load(file_path, sr=16000)
                
                # Double-check array lengths match target format exactly
                if len(audio) != TARGET_LENGTH:
                    audio = librosa.util.fix_length(audio, size=TARGET_LENGTH, mode='reflect')
                    
                X.append(audio)
                y.append(class_idx)
            except Exception as e:
                print(f"Error loading {file}: {e}")
                
    X = np.array(X, dtype=np.float32)
    y = np.array(y, dtype=np.int32)
    
    # One-hot encode classes for categorical cross-entropy
    y = to_categorical(y, num_classes=len(CLASSES))
    
    # Add a channel dimension for the 1D CNN: Shape becomes (Samples, 32000, 1)
    X = X[..., np.newaxis]
    
    # Split into Train, Validation, and Test matching your split format
    X_train, X_temp, y_train, y_temp = train_test_split(X, y, test_size=0.3, random_state=42, stratify=y)
    X_val, X_test, y_val, y_test = train_test_split(X_temp, y_temp, test_size=0.5, random_state=42, stratify=y_temp)
    
    # Save arrays locally
    np.save("X_train_1d.npy", X_train)
    np.save("X_val_1d.npy", X_val)
    np.save("X_test_1d.npy", X_test)
    np.save("y_train_1d.npy", y_train)
    np.save("y_val_1d.npy", y_val)
    np.save("y_test_1d.npy", y_test)
    
    print("\n✅ 1D Datasets saved successfully!")
    print(f"Train shape: {X_train.shape} | Val shape: {X_val.shape} | Test shape: {X_test.shape}")

if __name__ == "__main__":
    load_1d_dataset()