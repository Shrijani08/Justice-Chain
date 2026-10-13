# Remaining steps before the redesign and the phone session (14-10-2026)

This is the single to-do list from today until the demo. Work through it top to bottom. Phone testing is deliberately last, because the phones aren't available now. Each step says what it is in plain words, why it matters, what is needed from you, and how we will know it's done.

## Where things stand (checked 14-10-2026)

| Area | Status | How it was checked |
|---|---|---|
| App code health | 100 tests pass, 7 live tests skipped (they need the gateway); analyzer shows only 6 old `print` warnings in `main.dart` | `flutter test`, `flutter analyze` today |
| Recording, hashing (SHA-256), encryption, Shamir key pieces, outbox retry | Built and unit-tested | Test suite |
| Guardian pairing (QR), mesh relay | Built; last tested on phones 07-10 | 07-10 device test log |
| One-guardian mode (Option 2) | Built, committed `963e441d`, unit-tested; **never run on a phone** | Stand-alone check 14-10 |
| Ledger: app ↔ gateway ↔ Fabric anchoring | Built and live-tested from Dart; **not yet from a phone** | Live tests 12-10 |
| Police authority on the server (Steps 5–10, 12) | Built, committed, all live checks and 21/21 failure tests passed | Full re-verification 12-10 evening |
| Police authority **inside the app** (8d, 9c) | **Not built.** The app never calls `/nodes`, `/guardians`, `/authority-shares`, `/access-requests` or `/releases`; only tests do | Code search today |
| Release APK | Builds, has internet permission; **signed with the temporary debug key**, app ID still `com.example.justice_chain`, launcher name `justice_chain` | `build.gradle.kts`, manifest |
| Uncommitted | Release-build fix (manifest + `proguard-rules.pro`), DOCS edits | `git status` |

Separate tracks, not part of this list: the Raspberry Pi SOS device (its own 15-day plan; `device/` and `test/device_vectors_test.dart` are its uncommitted day-1 files), and the AI false-trigger fix and background listening (agreed out of scope on 11-10; presented as future work).

## The steps

### Step 1. Save the finished work (10 minutes, no decisions)
- **What:** commit the release-build fix (`AndroidManifest.xml` internet permission, `android/app/proguard-rules.pro`) and the DOCS notes from the 12-10 verification, plus this file.
- **Why:** they are finished and tested; leaving them uncommitted risks losing them or mixing them into later work.
- **Done when:** `git status` shows only the hardware files.

### Step 2. Pick the app's name and permanent ID (decision from you, then 30 minutes)
- **What:** choose the name (candidates: Kaavalu, Jothe, Sakshi …). Then set:
  - the name under the icon (today it shows `justice_chain`);
  - the permanent app ID, e.g. `in.kaavalu.app` instead of `com.example.justice_chain`;
  - the app icon (today it's the default Flutter icon).
- **Why now:** Android treats a new app ID as a different app. Changing it after the phone tests means reinstalling and re-pairing everything, and the Play Store refuses `com.example` IDs.
- **Needed from you:** the name, and an icon idea (or I draw one in the new design style).
- **Done when:** the release APK installs with the new name and icon (checked with `aapt`; seen on the phone in step 9).

### Step 3. A real signing key for the release APK (needs you once, 30 minutes)
- **What:**
  - create a signing key (a `.jks` file and a password);
  - store the password in `android/key.properties`, kept out of git;
  - tell Gradle to sign release builds with it.
- **Why:** the release APK is signed with a temporary debug key today. A proper key is needed to install updates over it later and to publish. **If the key or its password is lost, the app can never be updated**, so you keep a backup.
- **Needed from you:** a password, and somewhere safe for a backup copy of the key (not the repo).
- **Done when:** `flutter build apk --release` succeeds and `apksigner verify` shows your key, not the debug one.

### Step 4. App part of sharing with the police (8d), logic first (coding, no phones)
- **What:** teach the app the four things only the tests do today:
  1. **Register this phone** once on the ledger (its ID and keys, signed by the phone). Safe to repeat.
  2. **Keep the guardian list in sync** on the ledger whenever a guardian is added or removed, so the ledger knows who may release pieces.
  3. **Fetch the police authority's public key**, and show it only in demo builds (`--dart-define=DEMO_AUTHORITY=true`) with the "No real police are contacted. In an emergency call 112." notice.
  4. **After each recording**, if the victim has opted in, make one extra key piece, lock it to the police's key, sign the consent, and send it. It goes through the outbox, so it retries when offline.
- **Why:** this is what makes the police guardian real from the phone, not just from test scripts.
- **The screen** (the opt-in switch and notice) is built during the redesign (step 7), so it isn't built twice. Until then, the setting is switchable from code for testing.
- **Done when:**
  - unit tests with a fake gateway pass;
  - a live Dart test, using the app's own services against the real gateway, registers a phone, syncs guardians and shares a piece, and `check-authority-share.sh` confirms the officer can unseal it;
  - the full suite stays green.

### Step 5. App part of approvals (9c), logic first (coding, no phones)
- **What:**
  1. **Victim side:** list access requests from the police for my recordings, and approve one. Approving makes a new key piece, locks it to the police's key and releases it through the gateway.
  2. **Guardian side:** "Release my piece", which re-locks the guardian's own piece to the police's key and releases it.
  3. Both go through the outbox, so they retry when offline.
- **Why:** completes the approval flow the officer portal already expects.
- **The screens** ("Access requests", "Release my piece") are built in the redesign.
- **Done when:** a live Dart run of the whole story passes using the app's services: share → officer requests in the portal → victim *or* guardian releases → the portal opens the clip, with all checks passing and the audit trail showing every step.

### Step 6. Decide the open questions (decisions from you, no coding)
These were left open in earlier docs. Each needs a yes or no before the demo:
1. **Recovery code (Option 1):** build it, or present it as future work? Without it, a victim with no guardians who loses her phone can't recover her clips.
2. **Cloud deployment:** keep the network and gateway on the laptop for the demo (both phones on the same Wi-Fi), or move them to a cloud server so the demo doesn't depend on the laptop? If cloud, step 8 is added and needs your cloud account.
3. **AI false triggers:** keep as a known limitation for the presentation, or run the one-afternoon experiment from `DOCS/08-10-2026 AI false trigger analysis.md` (step 1 there) first?

### Step 7. UI redesign (after you approve the preview)
- **What:** build the approved design in Flutter, including the new screens for steps 4 and 5: the police opt-in, "Access requests" and "Release my piece".
- **Why after 4–5:** those screens are designed and built once, in the new style.
- **Done when:**
  - analyzer and tests are green;
  - a release build succeeds;
  - screenshots from an emulator match the preview. The real-phone check is in step 9.

### Step 8. Cloud deployment (only if chosen in step 6)
- **What:** run the Fabric network, gateway and portal on a cloud server; point `GATEWAY_URL` at it; secure the gateway (it has no login today; signatures prevent forgery, but anyone who can reach it can call it).
- **Done when:** the live Dart tests and failure tests pass against the cloud address.

### Step 9. Phone session (needs both phones; last)
In this order, on a fresh install of the signed release APK with the final name:
1. **Basics on two phones:** register, pair both ways by QR, Option-2 switch, AI listening, and SOS recording.
2. **4c, recording on Fabric:**
   - SOS on the victim phone gets uploaded, then appears on the ledger (gateway log and `/verify`);
   - the guardian phone's "Open and verify" shows "block N · gateway time …" and "signer is the victim";
   - the retry check: stop the gateway, record, start it again, and the clip is stored on its own.
3. **Mesh relay:** with the victim's phone offline, the guardian anchors the clip on the victim's behalf.
4. **8d and 9c on phones:** opt in to the police guardian, record, request in the portal, approve on the victim phone, then repeat with the guardian releasing instead.
5. **10b:** a clip recorded on the phone and uploaded through Pinata plays in the officer portal.
6. **Demo script:** run the phone steps of `DOCS/12-10-2026 simulated authority demo script.md` start to finish.
7. **Redesign on real hardware:** screenshots of every screen, checking for layout or text issues on both phones.

Then record the results in a device test log, commit, and tick 4c, 8d, 9c, 10b and Step 12 in the design-doc checklist.
