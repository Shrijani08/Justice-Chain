"""Option 1 after experiment 4 (DOCS/08-10-2026 AI false trigger analysis.md):
can Google's pretrained YAMNet (AudioSet, 521 classes) tell screams from
speech on the phone test set, where our model can't?

The rule is fixed before looking at results: a window's distress score is
the highest score of the distress classes below over YAMNet frames covering
the 2 s window; the app's "2 of the last 3 windows" rule is applied on top.

  E:/audio_dataset_project/venv/Scripts/python.exe tools/ai/score_yamnet.py \
      D:/Justice-Chain/ai_experiments/2026-10-14_exp2_vivo \
      D:/Justice-Chain/ai_experiments/models
Needs yamnet.tflite (MediaPipe's float32 YAMNet) and yamnet_class_map.csv
in the models folder. Writes yamnet_results.json and yamnet_results.md.
"""

import sysconfig

_schemes = sysconfig.get_scheme_names
sysconfig.get_scheme_names = lambda: tuple(s for s in _schemes() if "user" not in s)

import collections  # noqa: E402
import csv  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import sys  # noqa: E402

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import tensorflow as tf  # noqa: E402

N = 32000
FRAME = 15600  # YAMNet's input: 0.975 s at 16 kHz
OFFSETS = (0, 8200, N - FRAME)  # three frames covering the 2 s window
DISTRESS = ["Shout", "Bellow", "Yell", "Children shouting", "Screaming", "Crying, sobbing", "Whimper", "Wail, moan"]
LAUGH = ["Laughter", "Baby laughter", "Giggle", "Snicker", "Belly laugh", "Chuckle, chortle"]
THRESHOLDS = (0.1, 0.2, 0.3, 0.5)
OUR_THRESHOLD = 0.80


def load_wav(path):
    data, sr = sf.read(path, dtype="int16")
    assert sr == 16000 and len(data) == N, path
    return data.astype(np.float32) / 32768.0


def window_number(path):
    m = re.search(r"_w(\d+)_", os.path.basename(path))
    return int(m.group(1)) if m else 0


def would_trigger(passes):
    history, count = [], 0
    for p in passes:
        history = (history + [p])[-3:]
        if sum(history) >= 2:
            count += 1
            history = []
    return count


def main(exp_dir, models_dir):
    with open(os.path.join(models_dir, "yamnet_class_map.csv"), newline="") as f:
        names = [r["display_name"] for r in csv.DictReader(f)]
    distress_idx = [names.index(n) for n in DISTRESS]
    laugh_idx = [names.index(n) for n in LAUGH]

    interp = tf.lite.Interpreter(model_path=os.path.join(models_dir, "yamnet.tflite"))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]["index"]
    out = interp.get_output_details()[0]["index"]

    def scores(x):
        frames = []
        for o in OFFSETS:
            interp.set_tensor(inp, x[o:o + FRAME].astype(np.float32))
            interp.invoke()
            frames.append(interp.get_tensor(out)[0])
        return np.max(frames, axis=0)  # the strongest evidence in the window

    with open(os.path.join(exp_dir, "manifest.csv"), newline="") as f:
        rows = list(csv.DictReader(f))
    sets = collections.OrderedDict()
    for r in rows:
        sets.setdefault(r["set"], []).append(r)

    results = {"rule": {"distress_classes": DISTRESS, "laugh_classes": LAUGH, "frames_per_window": len(OFFSETS)}, "sets": {}}
    for name, items in sets.items():
        items = sorted(items, key=lambda r: window_number(r["file"]))
        s = [scores(load_wav(os.path.join(exp_dir, r["file"]))) for r in items]
        d = np.array([x[distress_idx].max() for x in s])
        lg = np.array([x[laugh_idx].max() for x in s])
        top = collections.Counter(names[int(np.argmax(x))] for x in s).most_common(5)
        our = np.array([r["app_p_distress"] != "" and float(r["app_p_distress"]) >= OUR_THRESHOLD and r["app_label"] == "distress" for r in items])
        entry = {
            "expected": items[0]["expected"],
            "clips": len(items),
            "yamnet_top_classes": top,
            "distress_flagged_pct": {str(t): round(100 * float(np.mean(d >= t))) for t in THRESHOLDS},
            "laugh_flagged_pct_at_0.3": round(100 * float(np.mean(lg >= 0.3))),
            "our_model_flagged_pct": round(100 * float(np.mean(our))),
            "our_model_and_yamnet_0.1_pct": round(100 * float(np.mean(our & (d >= 0.1)))),
        }
        if name == "speech":
            minutes = len(items) / 60
            entry["would_trigger_per_hour"] = {
                str(t): round(would_trigger(list(d >= t)) / minutes * 60) for t in THRESHOLDS
            }
            entry["would_trigger_per_hour"]["our model today"] = round(would_trigger(list(our)) / minutes * 60)
            entry["would_trigger_per_hour"]["our model + yamnet 0.1"] = round(
                would_trigger(list(our & (d >= 0.1))) / minutes * 60)
        results["sets"][name] = entry
        print(name, json.dumps(entry))

    with open(os.path.join(exp_dir, "yamnet_results.json"), "w") as f:
        json.dump(results, f, indent=1)
    lines = ["# YAMNet check on the phone test set", "",
             "Share of clips flagged as distress (highest distress-class score in the window at or above the threshold).", "",
             "| Set (should be) | Clips | YAMNet >= 0.1 | >= 0.2 | >= 0.3 | >= 0.5 | Our model today | Ours + YAMNet 0.1 |",
             "|---|---|---|---|---|---|---|---|"]
    for name, e in results["sets"].items():
        p = e["distress_flagged_pct"]
        lines.append(f"| {name} ({e['expected']}) | {e['clips']} | {p['0.1']}% | {p['0.2']}% | {p['0.3']}% | {p['0.5']}% | "
                     f"{e['our_model_flagged_pct']}% | {e['our_model_and_yamnet_0.1_pct']}% |")
    sp = results["sets"].get("speech", {}).get("would_trigger_per_hour", {})
    lines += ["", "Would-trigger per hour of plain speech (2 of the last 3 windows): " +
              ", ".join(f"{k}: {v}" for k, v in sp.items())]
    lines += ["", "YAMNet's most frequent top class per set:"]
    for name, e in results["sets"].items():
        lines.append(f"- {name}: " + ", ".join(f"{c} ({n})" for c, n in e["yamnet_top_classes"]))
    with open(os.path.join(exp_dir, "yamnet_results.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
