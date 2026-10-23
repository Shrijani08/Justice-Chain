# Plan: switch the automatic trigger to YAMNet (14-10-2026)

**Why:** in experiments 1–4 our own model false-triggered about 100 times per hour of ordinary talking, and caught only 17–38% of acted screams. Changing how the sound is prepared didn't fix it. On the same phone clips, Google's pretrained YAMNet flagged none of the 70 false triggers, made no false triggers on plain speech, and fired within seconds of the first scream. Details: `DOCS/08-10-2026 AI false trigger analysis.md`.

**Status (14-10-2026):** approved. The old model stays in capture mode only, and the targets are as below.
- **Steps 1, 2 and 4–7 built:** commit `323ebc62`; 164 tests pass.
- **Step 3 done on the Vivo:**
  - YAMNet loads with `tflite_flutter` as it is;
  - each 2 s window (3 frames) takes **91 ms median, 115 ms p95, 136 ms max** over 129 windows (target < 300 ms);
  - phone-vs-laptop parity on 16 saved windows: largest difference 0.004, same pass/fail 100%;
  - in about 2 minutes of talking, YAMNet passed **0** windows (top class "Speech" 101 times), while the old model, logged alongside, passed 16;
  - **the single short test scream scored only 0.15 (heard as "Animal"), below 0.2.** One scream is not an episode, and per this plan the threshold is tuned only once, in step 9, on the validation data. Watch this in step 8: if 10 s episodes are also missed on the Vivo, step 9 lowers the threshold.
- **Step 8 on the Vivo, part 1 done (15-10-2026, 18:52–20:06):** data in `D:/Justice-Chain/ai_experiments/2026-10-15_validation_vivo` (outside git: testers' voices), with `markers.txt` for when each part started.

  | Part | Windows with sound | YAMNet false triggers | Highest YAMNet score | Old model, windows passed |
  |---|---|---|---|---|
  | One speaker | 361 | **0** | 0.06 | 66 |
  | Conversation (4 min, then a call cut it off; 7 more min later) | 556 | **0** | 0.06 | 82 |
  | TV / music (two stretches) | 751 | **0** | 0.199 (twice, single windows, "Speech" from TV) | 10 |
  | **Total ≈ 28 min of sound** | 1,668 | **0** (target ≤ 2 per hour) | | 158 |

  - **Scream 1: detected about 1 s after it started** ("Crying; sobbing", 0.80).
  - **Screams 2–5: not done yet.** Scream 2 wasn't heard, because the app was off screen (see below). Redo them in daylight on 16-10.
  - **Inference:** 108 ms median, 144 ms p95 per 2 s window over 2,096 windows (one 1,075 ms outlier). Target < 300 ms: met.
  - **Threshold note:** TV twice reached 0.199. Lowering the threshold in step 9 would start to catch TV, so only lower it if the screams need it.
  - **Two app problems found (for step 6b):**
    1. after an incoming phone call took the microphone (19:05:07), listening never restarted, although the app came back on screen;
    2. when the app is not on screen (home screen, WhatsApp), the microphone gives exact zeros. This is the known reason for step 6b.
- **Next:** screams 2–5 on the Vivo (with the app kept on screen and calls blocked), then the Samsung session, then step 9.

## 1. What changes for the user

Nothing visible except fewer false recordings. The automatic trigger still:
- listens in 2 s windows, once per second;
- needs 2 of the last 3 windows to pass;
- keeps the 30 s cooldown after a recording;
- skips near-silence.

The SOS button and "112 =" are untouched.

## 2. Already checked

- **The phone can run it:** YAMNet's 16 operations are all built into TensorFlow Lite, including the audio FFT (`RFFT2D`, `COMPLEX_ABS`). No Select-TF ops or extra libraries are needed; `tflite_flutter` 0.11 should load it as it is. Step 3 confirms this on the phone first.
- **Model file:** MediaPipe's float32 `yamnet.tflite`, 4.1 MB, Apache 2.0, SHA-256 `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`.
  - **Input:** 15,600 samples (0.975 s at 16 kHz), raw waveform in −1..1. That is exactly what the app already has; no special preparation is needed.
  - **Output:** 521 class scores between 0 and 1.
- **The rule, as tested:**
  - a window's distress score is the highest of 8 classes, taken over 3 YAMNet frames covering the 2 s window (offsets 0, 8,200 and 16,400 samples);
  - the 8 classes are Shout (6), Bellow (7), Yell (9), Children shouting (10), Screaming (11), Crying/sobbing (19), Whimper (21) and Wail/moan (22), with the class-map index in brackets;
  - starting threshold **0.2**.

## 3. Steps, in order

| # | Step | What | Time |
|---|---|---|---|
| 1 | **Bundle the model** | Add `assets/models/yamnet.tflite` and list it in `pubspec.yaml`. Add `assets/models/YAMNET_NOTICE.txt` with the Apache 2.0 attribution. A test pins the file's SHA-256, so it can't be swapped silently. | 15 min |
| 2 | **New detector** | New `lib/core/yamnet_detector.dart`. It loads YAMNet, runs the 3 frames for a 2 s window, and returns the distress score and YAMNet's top class (for logs). The 8 class indices are constants with their names in comments. The scoring logic (frames, max, classes) is separated from the interpreter, so it can be unit-tested with a fake model. | 1 h |
| 3 | **First phone check** | Debug build on the Vivo: the model loads, inference time per frame is logged, and there are no errors. **If `tflite_flutter` can't load YAMNet**, stop here and report; the fallback is MediaPipe's audio classifier plugin, a bigger change. | 20 min (with you) |
| 4 | **Switch the trigger** | In `ai_service.dart`, the trigger uses the YAMNet score at ≥ 0.2. The 2-of-3 rule, cooldown, silence skip and `autoGain` stay as they are, so the conditions match the experiments. A trigger still reports the label `distress`, so `EmergencyController` needs no change. The home screen's AI line shows YAMNet's top class (e.g. "Speech", "Screaming") and the distress score instead of distress/happy/normal. | 1 h |
| 5 | **Keep the old model for comparison** | Normal builds load only YAMNet. In capture mode (`AI_CAPTURE=true`) the old model also runs, so each CSV row has both scores. The validation session then compares them live. The old model file stays in the repo with its measured results. | 30 min |
| 6 | **Capture CSV columns** | Add `yamnet_distress`, `yamnet_top_class` and `infer_ms`, and keep the old model's columns. A window is saved as WAV when *either* model passes. `tools/ai/score_yamnet.py` gets a check that the phone's YAMNet scores match the laptop's for the same saved WAVs (like experiment 3). | 30 min |
| 7 | **Tests** | Unit tests: frame offsets and max-over-frames with a fake model; the 8 indices match the names in `yamnet_class_map.csv` (kept as a test fixture); the model hash; the existing debounce test unchanged. Run the full suite and the analyzer. | 1 h |
| 8 | **Validation session (with you), on the Vivo and then the Samsung** | Capture mode, about 30 min per phone: 10 min one speaker, 10 min conversation, 10 min TV/music, then **5 scream episodes** (each about 10 s of screaming or shouting for help, with a minute of normal talk between). | about 1 h per phone |
| 9 | **Decide and document** | Compare against the targets below. If needed, adjust the threshold **once**, using the Vivo data, and check it on the Samsung data without tuning again, so the Samsung result is honest. Update the analysis doc, the remaining-steps doc and the presentation numbers. | 30 min |

## 4. Targets for the validation session

| Measure | Target | Today's model |
|---|---|---|
| False recordings per hour of talk/TV | **≤ 2** | about 100 |
| Scream episodes detected (at least one trigger within 5 s) | **≥ 4 of 5** on each phone | not measured per episode; 17–38% of scream windows |
| Inference time per 2 s window (3 YAMNet frames) | **< 300 ms** on both phones | n/a |

If the targets are met, automatic detection is presented with these real numbers. If not, it is presented as a prototype with measured limits, and retraining (analysis doc, plan step 2) becomes the next AI task.

## 5. Risks

- **Loading:** `tflite_flutter`'s bundled runtime might not support an operation on one of the phones. Step 3 checks this before anything else depends on it.
- **Overfitting:** the threshold of 0.2 was looked at on the same clips that showed YAMNet works. Step 8's new recordings, and the "tune on Vivo, check on Samsung" rule, keep the final numbers honest.
- **Shouted words:** YAMNet often hears "Help!" as Speech. Screaming and crying are detected better. Report this as a known limit; the SOS button and "112 =" cover the rest.
- **Battery and heat:** three small inferences per second instead of one. Inference time is logged; battery drain is measured in step 6b (background listening).
- **App size:** 4.1 MB more.

## 6. Decisions for you

1. **Go ahead with steps 1–7?**
2. **Keep the old model running in capture mode only** (as planned), or remove it from the app entirely?
3. **The targets in section 4:** OK as they are?
