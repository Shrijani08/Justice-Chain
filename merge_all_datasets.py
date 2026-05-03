import os
import shutil
import pandas as pd

# Base paths
base_path = r"E:\audio_dataset_project"
output_path = os.path.join(base_path, "final_dataset")

distress_path = os.path.join(output_path, "distress")
happy_path = os.path.join(output_path, "happy")
normal_path = os.path.join(output_path, "normal")

# Create clean folders
os.makedirs(distress_path, exist_ok=True)
os.makedirs(happy_path, exist_ok=True)
os.makedirs(normal_path, exist_ok=True)

def safe_copy(src, dest_folder):
    if os.path.exists(src):
        dest = os.path.join(dest_folder, os.path.basename(src))
        if not os.path.exists(dest):
            shutil.copy(src, dest)

# 1. DISTRESS POOL (Augmented + Raw + Specific Danger/SESA classes)
# Augmented folders
aug_folders = ["augmented_data", "augmented_data2", "augmented_data3", "clean_augmented_data"]
for folder in aug_folders:
    path = os.path.join(base_path, folder)
    if os.path.exists(path):
        for file in os.listdir(path):
            if file.lower().endswith(".wav"):
                safe_copy(os.path.join(path, file), distress_path)

# Raw Screams/Help
raw_path = os.path.join(base_path, "dataset_raw")
for sub in ["help", "scream"]:
    sub_path = os.path.join(raw_path, sub)
    if os.path.exists(sub_path):
        for file in os.listdir(sub_path):
            if file.lower().endswith(".wav"):
                safe_copy(os.path.join(sub_path, file), distress_path)

# 2. HAPPY POOL (The Harvesting Fix)
# Use your already-organized ESC-50 Happy folder
esc_happy_src = os.path.join(base_path, "esc-50-audio-processed", "happy")
if os.path.exists(esc_happy_src):
    for file in os.listdir(esc_happy_src):
        if file.lower().endswith(".wav"):
            safe_copy(os.path.join(esc_happy_src, file), happy_path)

# 3. NORMAL POOL
# Use your already-organized ESC-50 Normal folder
esc_normal_src = os.path.join(base_path, "esc-50-audio-processed", "normal")
if os.path.exists(esc_normal_src):
    for file in os.listdir(esc_normal_src):
        if file.lower().endswith(".wav"):
            safe_copy(os.path.join(esc_normal_src, file), normal_path)

# Raw Ambient Normal
raw_normal = os.path.join(raw_path, "normal")
if os.path.exists(raw_normal):
    for file in os.listdir(raw_normal):
        if file.lower().endswith(".wav"):
            safe_copy(os.path.join(raw_normal, file), normal_path)

# 4. DANGER DATASET (Women/Child -> Distress, Normal -> Normal)
danger_base = os.path.join(base_path, "danger_dataset")
for split in ["train", "test"]:
    split_path = os.path.join(danger_base, split)
    for cls in ["Women", "Child"]:
        cls_path = os.path.join(split_path, cls)
        if os.path.exists(cls_path):
            for file in os.listdir(cls_path):
                safe_copy(os.path.join(cls_path, file), distress_path)
    
    norm_cls = os.path.join(split_path, "Normal")
    if os.path.exists(norm_cls):
        for file in os.listdir(norm_cls):
            safe_copy(os.path.join(norm_cls, file), normal_path)

# 5. URBAN SOUND 8K (Smart Filtering)
meta_path = os.path.join(base_path, "UrbanSound8K", "metadata", "UrbanSound8K.csv")
audio_path = os.path.join(base_path, "UrbanSound8K", "audio")

if os.path.exists(meta_path):
    df = pd.read_csv(meta_path)
    for _, row in df.iterrows():
        file_path = os.path.join(audio_path, f"fold{row['fold']}", row['slice_file_name'])
        category = row["class"]
        
        if category in ["gun_shot", "explosion"]:
            safe_copy(file_path, distress_path)
        elif category == "children_playing":
            # REASSIGNING TO HAPPY to fix the imbalance
            safe_copy(file_path, happy_path)
        else:
            safe_copy(file_path, normal_path)

print("🔥 CLEAN MERGE COMPLETE! Check your final_dataset folder counts.")