# AI False Trigger Analysis: 08-10-2026

Follows the 07-10-2026 device test, where ordinary speech started recordings **at least 9 times** across both phones (83–100% "distress"). This note records what the distress model is, two likely causes, and the plan. **Nothing has been changed yet.** Both causes are hypotheses until step 1 runs.

## What the model is

- **On-device model:** `assets/models/distress_model.tflite`, a 1D CNN trained from scratch on raw 2 s waveforms at 16 kHz (32,000 samples). Classes: `distress` / `happy` / `normal` (`assets/models/labels.txt`).
- **Pipeline:**
  1. `merge_all_datasets.py` sorts sources into the 3 classes.
  2. `preprocess_audio.py` prepares each clip.
  3. `generate_1d_dataset.py` saves the `.npy` splits (70/15/15, random, stratified).
  4. `train_cnn_1D.py` trains for 25 epochs.
  5. `convert_to_tflite.py` converts with dynamic-range quantisation and `SELECT_TF_OPS`.
- **App side** (`lib/core/ai_service.dart`):
  - Mic stream: PCM16 at 16 kHz with `autoGain: true`, divided by 32768. Inference every 1 s on the last 2 s.
  - Threshold 0.80; needs 2 of the last 3 windows to pass.
  - 30 s cooldown after each recording (added 07-10, commit `d881ce1f`).
  - Windows below RMS 0.005 are treated as silence.

## Suspect A: app preprocessing doesn't match training

| Step | Training (`preprocess_audio.py`) | App (`ai_service.dart`) |
|---|---|---|
| Pre-emphasis (librosa default, coef 0.97) | Applied | **Not applied** |
| RMS normalisation to 0.1 | Applied | **Not applied** (raw mic level) |
| Automatic gain | n/a | `autoGain: true` |
| Silence trim | `top_db=40` | none (RMS < 0.005 skipped) |
| Window choice | Highest-energy 2 s of each clip | Every 2 s, sliding by 1 s |

Every live window is out of distribution, so scores on live audio may be meaningless. **If this is the cause, the fix is about 10 lines of Dart:** pre-emphasis, RMS normalisation to 0.1, and probably `autoGain: false`. **No retraining.**

## Suspect B: training labels teach "voice = distress"

Counted on `E:/audio_dataset_project` (08-10-2026):

| Class | Clips | Sources |
|---|---|---|
| distress | 14,016 | **About 13,000 from `danger_dataset` "Women" + "Child"** (train: 4,498 + 4,542, plus test), copied in wholesale. Own recordings: **only 15 "help" + 3 "scream"**. Augmented: 360 + 360 + 360 + 400, many literal duplicates (`… - Copy - Copy (2)_mono.wav`). Plus UrbanSound8K gun_shot/explosion. |
| normal | 15,717 | ESC-50 and UrbanSound8K environmental sounds, `danger_dataset` "Normal", 15 own "normal" recordings |
| happy | 1,080 | Laughter, giggle, applause, cheering (AudioSet-based), UrbanSound8K children_playing |

Risks:
- **Ordinary adult conversation is probably almost absent from "normal"**, while a whole folder of women's and children's voices is labelled distress. The model may have learned "human voice means distress", which matches the device test.
- **Not yet verified:** what `danger_dataset` "Women"/"Child" actually contain. Listen to a sample before concluding.
- **Data leakage:** variants of one recording (`1_0.wav`, `1_0_left.wav`, `1_0_right.wav`, `1_0_patch.wav`) and duplicated augmented copies were split randomly, so near-copies sit in both train and test. **The reported test accuracy is inflated; don't quote it in the presentation.**
- Class imbalance: happy has about 1/14 the clips of the other classes, and no class weights were used.

## Also note

- `live_detection.py` and `README.md` describe a **different model**: a 2D mel-spectrogram CNN (`justice_chain_model.h5`, 128×128 input) with its own preprocessing. The app ships the 1D CNN. Align the docs so the presentation doesn't mix them up.
- `DOCS/AI_DISTRESS_INTEGRATION_REPORT.md` still describes live inference as a placeholder; it is out of date.

## Experiment 1 results (14-10-2026, Vivo V2239, Android 15)

**Setup:**
- Debug build with `--dart-define=AI_CAPTURE=true` (`lib/core/ai_capture.dart`). Every 2 s window's scores went to `windows.csv`, and every window scoring ≥ 80% distress was saved as a 16 kHz WAV, exactly as the model saw it.
- In capture mode a confirmed trigger is only logged ("would trigger"), so listening never paused.
- The app's real rule applied: threshold 0.80, 2 of the last 3 windows, autoGain on.
- Data (not in git; contains the testers' voices): `D:\Justice-Chain\ai_experiments\2026-10-14_exp1_vivo\`. It holds `raw/` (CSV + WAVs), `false_triggers/<part>/` and `summary.json`.

| Part | What | Minutes | Windows labelled distress | Windows ≥ 80% | Would have recorded | Per hour |
|---|---|---|---|---|---|---|
| Silence | quiet room | 2.9 | 0 | 0 | 0 | 0 |
| A | one person reading or talking | 3.0 | 38 | 24 | 8 | ~157 |
| B | conversation, 2+ people | 4.2 | 13 | 7 | 2 | ~29 |
| C | TV, video or music | 5.7 | 58 | 39 | 12 | ~127 |
| **All talking** | | **12.9** | 109 | 70 | **22** | **~102** |

**What it shows:**
- The model is sensible on silence: highest distress score 29%.
- Ordinary voices make it fire about **100 times an hour**, often at 95–100% confidence. One steady speaker and TV/media are the worst cases.
- This confirms the 07-10 device test with numbers. It doesn't yet say *why* (Suspect A or B); experiment 4 does, using these 70 WAVs as the "false triggers" set.

## Experiment 2 results (14-10-2026, Vivo): the phone test set

**Setup:**
- Same capture build plus `--dart-define=AI_CAPTURE_ALL=true`, so every 2 s window was saved, as the app sees it.
- Parts:
  - S: plain speech, 20:41:28–20:44:11;
  - D: acted screams and shouted calls for help, in short bursts with pauses, 20:44:11–20:47:14;
  - H: laughter, 20:47:14–20:48:28.
- Only the bursts count for D and H: windows with RMS ≥ 0.05. The quiet pauses between bursts are left out.
- Data (outside git): `D:\Justice-Chain\ai_experiments\2026-10-14_exp2_vivo\`, with `test_set/{speech,distress,happy,false_triggers}` and `manifest.csv` listing each file, its expected class and the app's scores. The false triggers come from experiment 1.

| Set | Windows | Should be | App said | App right |
|---|---|---|---|---|
| speech | 154 | normal | normal 114, **distress 39**, happy 1 | 74% |
| distress (acted screams and shouts) | 124 | distress | **normal 101**, distress 21, happy 2 | **17%** |
| happy (laughter) | 52 | happy | normal 44, distress 8 | **0%** |
| false triggers (experiment 1) | 70 | normal | distress 70 | 0% |

**What it shows:** with the app's current preprocessing, the model is **more likely to call plain speech "distress" (25%) than an actual scream (17%)**, and it never recognises laughter. As the app runs it today, it isn't detecting distress at all. Experiment 4 tests whether the training preprocessing changes that (Suspect A) or not (Suspect B). Screams from the dataset's test split will be added on the computer for that comparison.

**Also found:** when the phone is locked or the app isn't on screen, Android gives the app no microphone. Automatic detection only works with Sakshya open. This is planned as step 6b (foreground service) in `DOCS/14-10-2026 remaining steps.md`.

## Plan (in order; ask before retraining)

1. **Experiment to tell A from B (a few hours):**
   - Add a `kDebugMode`-only option in `ai_service.dart` that saves each 2 s window passing the threshold. Pull the files with `adb`.
   - Also record a few minutes of ordinary conversation on the phone, and take some screams from the test split.
   - In the venv, load `distress_model.tflite`. Score every window twice: once with the **app's** preprocessing, once with the **training** preprocessing.
   - Check that the TFLite output matches `justice_chain_1d_model` (Keras) on identical input, since quantisation and Select-TF ops could change results.
   - **If matching preprocessing removes most speech false positives:** Suspect A. Fix the Dart preprocessing, re-test on the phones, done.
   - **If speech still scores as distress:** Suspect B. Go to step 2.
2. **Retrain, only if step 1 shows it's the data:**
   - Add hard negatives: conversational speech (LibriSpeech / Common Voice) and the captured phone windows.
   - Review what `danger_dataset` Women/Child contains; relabel if it is ordinary speech.
   - Split by **original recording/source**, not randomly, so variants can't leak.
   - Use class weights for `happy`.
   - Report a confusion matrix and **false triggers per hour of ordinary speech**, and tune the threshold against that.
3. **Second model, only if steps 1–2 aren't enough:**
   - An ensemble trained on the same data shares its blind spot, so it isn't the answer.
   - Use a **pretrained general audio classifier, e.g. YAMNet** (AudioSet, TFLite, 16 kHz input). Either:
     - as a gate: don't trigger when the top class is ordinary speech; allow screaming or shouting, or
     - as a feature extractor with a small classifier trained on our data.
   - Check its actual class-map names before wiring it in.

## Related open item from 07-10

- Samsung A33: a recording failed to stop (`Failed to cleanly stop camera recording layers`, 21:38:24) and the clip was lost. The camera also needed the start-retry 3 times. Separate from the AI issue, but the AI false triggers made it occur more often.
