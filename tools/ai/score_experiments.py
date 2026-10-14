"""Experiments 3 and 4 of DOCS/08-10-2026 AI false trigger analysis.md.

Experiment 3: does the app's TFLite model give the same answers as the
original Keras model (justice_chain_1d_model) on identical input?

Experiment 4: score every clip of the phone test set (experiment 2) with
the app's preprocessing and with the training preprocessing
(preprocess_audio.py), plus each training step on its own, to tell a
preprocessing mismatch (Suspect A) from training data that labels voices as
distress (Suspect B). The training split's own test clips are scored too, as
the "model on its home ground" baseline.

Run with the dataset venv (E: drive):
  E:/audio_dataset_project/venv/Scripts/python.exe tools/ai/score_experiments.py \
      D:/Justice-Chain/ai_experiments/2026-10-14_exp2_vivo
Writes results.json and results.md into that folder.
"""

import sysconfig

# A broken DirectML plugin in the user site-packages stops TensorFlow from
# loading; keep TensorFlow from scanning the user install location.
_schemes = sysconfig.get_scheme_names
sysconfig.get_scheme_names = lambda: tuple(s for s in _schemes() if "user" not in s)

import csv  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import sys  # noqa: E402

import librosa  # noqa: E402
import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import tensorflow as tf  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TFLITE = os.path.join(REPO, "assets", "models", "distress_model.tflite")
TRAIN_DIR = r"E:\justice chain 2\Justice-Chain"
KERAS_DIR = os.path.join(TRAIN_DIR, "justice_chain_1d_model")
CLASSES = ["distress", "happy", "normal"]
SR = 16000
N = 32000
THRESHOLD = 0.80


# --- Preprocessing ------------------------------------------------------

def app_preprocess(x):
    """What lib/core/ai_service.dart feeds the model: int16 / 32768, nothing else."""
    return x


def preemphasis_only(x):
    return librosa.effects.preemphasis(x)


def rms_only(x):
    rms = np.sqrt(np.mean(x ** 2))
    return x * (0.1 / rms) if rms > 1e-6 else x


def training_preprocess(x):
    """preprocess_audio.py steps 2-8 on a 2 s window, including its PCM_16 save."""
    audio = librosa.effects.preemphasis(x)
    trimmed, _ = librosa.effects.trim(audio, top_db=40)
    if len(trimmed) >= 0.5 * N:
        audio = trimmed
    if len(audio) > N:  # can't happen for a 2 s window; kept for fidelity
        audio = audio[:N]
    else:
        audio = librosa.util.fix_length(audio, size=N, mode="reflect")
    rms = np.sqrt(np.mean(audio ** 2))
    if rms > 1e-6:
        audio = audio * (0.1 / rms)
    # Training clips were written as PCM_16 and read back: clip and quantise.
    return np.round(np.clip(audio, -1.0, 32767 / 32768) * 32768) / 32768


VARIANTS = {
    "app (today)": app_preprocess,
    "+ pre-emphasis only": preemphasis_only,
    "+ RMS to 0.1 only": rms_only,
    "training (all steps)": training_preprocess,
}


# --- Models -------------------------------------------------------------

class TfliteModel:
    def __init__(self, path):
        self.interp = tf.lite.Interpreter(model_path=path)
        self.interp.allocate_tensors()
        self.inp = self.interp.get_input_details()[0]["index"]
        self.out = self.interp.get_output_details()[0]["index"]

    def predict(self, x):
        self.interp.set_tensor(self.inp, x.reshape(1, N, 1).astype(np.float32))
        self.interp.invoke()
        return self.interp.get_tensor(self.out)[0].astype(float)


class KerasModel:
    """The original SavedModel, run as a graph (its optimizer state won't
    restore under Keras 3, and inference doesn't need it)."""

    def __init__(self, path):
        tf1 = tf.compat.v1
        self.sess = tf1.Session(graph=tf.Graph())
        meta = tf1.saved_model.loader.load(self.sess, ["serve"], path)
        sig = meta.signature_def["serving_default"]
        self.inp = list(sig.inputs.values())[0].name
        self.out = list(sig.outputs.values())[0].name

    def predict_batch(self, xs):
        return self.sess.run(self.out, {self.inp: xs.reshape(-1, N, 1).astype(np.float32)})


# --- Helpers ------------------------------------------------------------

def load_wav(path):
    data, sr = sf.read(path, dtype="int16")
    assert sr == SR and len(data) == N, path
    return data.astype(np.float32) / 32768.0


def window_number(path):
    m = re.search(r"_w(\d+)_", os.path.basename(path))
    return int(m.group(1)) if m else 0


def would_trigger(passes):
    """The app's rule: 2 of the last 3 windows pass; the history resets after a trigger."""
    history, count = [], 0
    for p in passes:
        history = (history + [p])[-3:]
        if sum(history) >= 2:
            count += 1
            history = []
    return count


def summarise(probs, expected):
    probs = np.asarray(probs)
    labels = [CLASSES[i] for i in probs.argmax(axis=1)]
    counts = {c: labels.count(c) for c in CLASSES}
    return {
        "clips": len(labels),
        "labels": counts,
        "correct_pct": round(100 * counts.get(expected, 0) / len(labels)),
        "distress_over_80pct_pct": round(100 * float(np.mean(probs[:, 0] >= THRESHOLD))),
        "mean_p_distress": round(float(probs[:, 0].mean()), 3),
    }


# --- Main ---------------------------------------------------------------

def main(exp_dir):
    tflite = TfliteModel(TFLITE)
    keras = KerasModel(KERAS_DIR)

    with open(os.path.join(exp_dir, "manifest.csv"), newline="") as f:
        rows = list(csv.DictReader(f))
    clips = {r["file"]: load_wav(os.path.join(exp_dir, r["file"])) for r in rows}
    print(f"Loaded {len(clips)} phone clips")

    # Experiment 3: TFLite vs Keras on identical input (phone clips, both preprocessings).
    sample = [rows[i]["file"] for i in np.linspace(0, len(rows) - 1, 120).astype(int)]
    inputs = np.stack([fn(clips[f]) for f in sample for fn in (app_preprocess, training_preprocess)])
    k = keras.predict_batch(inputs)
    t = np.stack([tflite.predict(x) for x in inputs])
    exp3 = {
        "inputs": len(inputs),
        "max_abs_diff": round(float(np.abs(k - t).max()), 4),
        "mean_abs_diff": round(float(np.abs(k - t).mean()), 5),
        "same_label_pct": round(100 * float(np.mean(k.argmax(1) == t.argmax(1))), 1),
    }
    print("Experiment 3:", exp3)

    # Experiment 4: each set x each preprocessing, with the app's TFLite model.
    sets = {}
    for r in rows:
        sets.setdefault(r["set"], {"expected": r["expected"], "files": []})["files"].append(r["file"])
    exp4 = {}
    for name, s in sets.items():
        exp4[name] = {"expected": s["expected"], "variants": {}}
        for vname, fn in VARIANTS.items():
            probs = [tflite.predict(fn(clips[f])) for f in s["files"]]
            result = summarise(probs, s["expected"])
            if name == "speech":
                ordered = sorted(zip(s["files"], probs), key=lambda fp: window_number(fp[0]))
                passes = [p[0] >= THRESHOLD and int(np.argmax(p)) == 0 for _, p in ordered]
                minutes = len(passes) / 60
                result["would_trigger"] = would_trigger(passes)
                result["would_trigger_per_hour"] = round(result["would_trigger"] / minutes * 60)
            exp4[name]["variants"][vname] = result
            print(name, vname, result)

    # Baseline: the training split's own test clips (already preprocessed), 300 per class at most.
    X = np.load(os.path.join(TRAIN_DIR, "X_test_1d.npy"), mmap_mode="r")
    y = np.load(os.path.join(TRAIN_DIR, "y_test_1d.npy")).argmax(1)
    rng = np.random.default_rng(42)
    baseline = {}
    for ci, cls in enumerate(CLASSES):
        idx = rng.choice(np.where(y == ci)[0], size=min(300, int((y == ci).sum())), replace=False)
        probs = [tflite.predict(np.asarray(X[i]).reshape(-1)) for i in sorted(idx)]
        baseline[cls] = summarise(probs, cls)
        print("dataset test split", cls, baseline[cls])

    results = {"experiment3_tflite_vs_keras": exp3, "experiment4": exp4, "dataset_test_split": baseline}
    with open(os.path.join(exp_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    write_markdown(exp_dir, results)


def write_markdown(exp_dir, results):
    lines = ["# Experiments 3 and 4 results", ""]
    e3 = results["experiment3_tflite_vs_keras"]
    lines += [
        "## Experiment 3: phone model (TFLite) vs original model (Keras)",
        "",
        f"{e3['inputs']} identical inputs: same label {e3['same_label_pct']}%, "
        f"largest difference {e3['max_abs_diff']}, average {e3['mean_abs_diff']}.",
        "",
        "## Experiment 4: phone test set, app preprocessing vs training preprocessing",
        "",
        "| Set (should be) | Preprocessing | Correct | distress >= 80% | Labels (distress/happy/normal) | Would-trigger per hour |",
        "|---|---|---|---|---|---|",
    ]
    for name, s in results["experiment4"].items():
        for vname, r in s["variants"].items():
            lab = r["labels"]
            per_hour = r.get("would_trigger_per_hour", "")
            lines.append(
                f"| {name} ({s['expected']}) | {vname} | {r['correct_pct']}% | {r['distress_over_80pct_pct']}% | "
                f"{lab['distress']}/{lab['happy']}/{lab['normal']} | {per_hour} |"
            )
    lines += ["", "## Baseline: the training split's own test clips", "",
              "| Class | Clips | Correct | Labels (distress/happy/normal) |", "|---|---|---|---|"]
    for cls, r in results["dataset_test_split"].items():
        lab = r["labels"]
        lines.append(f"| {cls} | {r['clips']} | {r['correct_pct']}% | {lab['distress']}/{lab['happy']}/{lab['normal']} |")
    with open(os.path.join(exp_dir, "results.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
