import os
import pandas as pd
import shutil

# ==============================
# PATHS (EDIT ONLY IF NEEDED)
# ==============================
base_path = r"D:\Downloads\vs-release"

audio_path = os.path.join(base_path, "audio_16k")
meta_path = os.path.join(base_path, "meta", "all_meta.csv")
label_map_path = os.path.join(base_path, "class_labels_indices_vs.csv")

output_path = r"E:\audio_dataset_project\final_dataset\happy"

os.makedirs(output_path, exist_ok=True)

# ==============================
# LOAD FILES
# ==============================
df = pd.read_csv(meta_path)
label_map = pd.read_csv(label_map_path)

print("Columns in metadata:", df.columns)

# ==============================
# FIND HAPPY LABEL IDS
# ==============================
happy_keywords = ["laughter", "giggle", "applause", "cheering"]

happy_labels = label_map[
    label_map['display_name'].str.lower().str.contains('|'.join(happy_keywords))
]

happy_ids = happy_labels['index'].astype(str).tolist()

print("✅ Happy label IDs:", happy_ids)

# ==============================
# DETECT COLUMN NAMES
# ==============================
# Adjust automatically based on dataset format
if 'filename' in df.columns:
    file_col = 'filename'
elif 'file_name' in df.columns:
    file_col = 'file_name'
else:
    raise Exception("❌ Cannot find filename column")

if 'labels' in df.columns:
    label_col = 'labels'
elif 'label' in df.columns:
    label_col = 'label'
else:
    raise Exception("❌ Cannot find label column")

# ==============================
# FILTER AND COPY FILES
# ==============================
count = 0

for _, row in df.iterrows():
    labels = str(row[label_col])

    if any(h_id in labels for h_id in happy_ids):
        filename = row[file_col]
        src = os.path.join(audio_path, filename)

        if os.path.exists(src):
            dst = os.path.join(output_path, filename)

            if not os.path.exists(dst):
                shutil.copy(src, dst)
                count += 1

print(f"🔥 DONE! {count} happy files extracted.")