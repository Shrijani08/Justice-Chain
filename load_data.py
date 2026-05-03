import os
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.utils import shuffle
from tensorflow.keras.utils import to_categorical

# --- CONFIGURATION ---
DATA_PATH = r"E:\audio_dataset_project\spectrogram_dataset"
CLASSES = ["distress", "happy", "normal"]

def load_data():
    X = []
    y = []
    
    for idx, cls in enumerate(CLASSES):
        folder_path = os.path.join(DATA_PATH, cls)
        print(f"📦 Loading {cls} features from disk...")
        
        files = [f for f in os.listdir(folder_path) if f.endswith(".npy")]
        total_files = len(files)
        
        for i, file in enumerate(files):
            try:
                data = np.load(os.path.join(folder_path, file))
                X.append(data)
                y.append(idx)
                
                if (i + 1) % 1000 == 0:
                    print(f"  > Loaded {i + 1}/{total_files} for {cls}")
                    
            except Exception as e:
                print(f"  ❌ Failed to load {file}: {e}")
                
    print("\n🔄 Converting to NumPy arrays...")
    X = np.array(X, dtype='float32')
    y = np.array(y)  # IMPORTANT: keep as 1D labels for stratify
    
    return X, y

# --- EXECUTION ---
if __name__ == "__main__":
    # 1. Load data
    X, y = load_data()

    print(f"📊 Total Dataset: {X.shape[0]} samples")

    # 2. Shuffle (important)
    X, y = shuffle(X, y, random_state=42)

    # 3. First split (Train + Temp)
    X_train, X_temp, y_train_raw, y_temp_raw = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    # 4. Second split (Validation + Test)
    X_val, X_test, y_val_raw, y_test_raw = train_test_split(
        X_temp, y_temp_raw, test_size=0.5, random_state=42, stratify=y_temp_raw
    )

    # 5. One-hot encoding AFTER split
    y_train = to_categorical(y_train_raw, num_classes=len(CLASSES))
    y_val   = to_categorical(y_val_raw, num_classes=len(CLASSES))
    y_test  = to_categorical(y_test_raw, num_classes=len(CLASSES))

    print("\n✅ Splitting Complete:")
    print(f"   Train: {X_train.shape[0]}")
    print(f"   Val:   {X_val.shape[0]}")
    print(f"   Test:  {X_test.shape[0]}")

    # 6. SAVE DATA
    print("\n💾 Saving dataset checkpoints...")

    np.save("X_train.npy", X_train)
    np.save("X_val.npy", X_val)
    np.save("X_test.npy", X_test)

    np.save("y_train.npy", y_train)
    np.save("y_val.npy", y_val)
    np.save("y_test.npy", y_test)

    print("\n🔥 ALL SYSTEMS GO! Ready for training.")