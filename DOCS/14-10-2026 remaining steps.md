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
| Police authority **inside the app** (8d, 9c) | Logic built and live-tested from Dart (steps 4 and 5 below); screens come with the redesign; **not yet on a phone** | Live tests 14-10 |
| Release APK | Builds, has internet permission; **signed with the temporary debug key**, app ID still `com.example.justice_chain`, launcher name `justice_chain` | `build.gradle.kts`, manifest |
| Uncommitted | Release-build fix (manifest + `proguard-rules.pro`), DOCS edits | `git status` |

Separate tracks, not part of this list: the Raspberry Pi SOS device (its own 15-day plan; `device/` and `test/device_vectors_test.dart` are its uncommitted day-1 files), and the AI false-trigger fix and background listening (agreed out of scope on 11-10; presented as future work).

## The steps

### Step 1. Save the finished work (10 minutes, no decisions) — done 14-10-2026, commit `df762fe1`
- **What:** commit the release-build fix (`AndroidManifest.xml` internet permission, `android/app/proguard-rules.pro`) and the DOCS notes from the 12-10 verification, plus this file.
- **Why:** they are finished and tested; leaving them uncommitted risks losing them or mixing them into later work.
- **Done when:** `git status` shows only the hardware files.

### Step 2. Pick the app's name and permanent ID — done 14-10-2026, commit `914af2e7` (final icon still to choose)
**Decided 14-10-2026:**
- **Name:** **Sakshya** (साक्ष्य, "evidence, testimony").
- **App ID:** `in.sakshya.app`. Only `applicationId` changes; the code's `namespace` and Kotlin package stay `com.example.justice_chain`, since users never see them.
- **Icon:** choose later from the three prototype designs (tag, monogram, seal). The tag is used as a placeholder until then; swapping it later is just an image change.
- **What:** choose the name (candidates: Kaavalu, Jothe, Sakshi …). Then set:
  - the name under the icon (today it shows `justice_chain`);
  - the permanent app ID, e.g. `in.kaavalu.app` instead of `com.example.justice_chain`;
  - the app icon (today it's the default Flutter icon).
- **Why now:** Android treats a new app ID as a different app. Changing it after the phone tests means reinstalling and re-pairing everything, and the Play Store refuses `com.example` IDs.
- **Needed from you:** the name, and an icon idea (or I draw one in the new design style).
- **Done when:** the release APK installs with the new name and icon (checked with `aapt`; seen on the phone in step 9).

### Step 3. A real signing key for the release APK — done 14-10-2026
**Result:**
- **Key:** `android/sakshya-upload.jks` (alias `upload`, RSA 2048, valid 10,000 days), with its password in `android/key.properties`. Both are git-ignored.
- **Build:** `android/app/build.gradle.kts` signs release builds with this key, and falls back to the debug key with a warning when `key.properties` is missing.
- **Verified:** `apksigner verify --print-certs` reports `CN=Sakshya, O=Justice-Chain project, L=Bengaluru, ST=Karnataka, C=IN`. Certificate SHA-256 `f3bfb660ff94c45121dd3a260f065df4da4e46a11cf76d886f28a6bd34438d10`; every future release must show this same fingerprint.
- **Backup:** keep the `.jks` and `key.properties` together, off this laptop.
- **What:**
  - create a signing key (a `.jks` file and a password);
  - store the password in `android/key.properties`, kept out of git;
  - tell Gradle to sign release builds with it.
- **Why:** the release APK is signed with a temporary debug key today. A proper key is needed to install updates over it later and to publish. **If the key or its password is lost, the app can never be updated**, so you keep a backup.
- **Needed from you:** a password, and somewhere safe for a backup copy of the key (not the repo).
- **Done when:** `flutter build apk --release` succeeds and `apksigner verify` shows your key, not the debug one.

### Step 4. App part of sharing with the police (8d), logic first — done 14-10-2026 (screens come with the redesign)
**Result:**
- **Code:** `lib/core/authority_service.dart` plus gateway calls in `fabric_ledger_service.dart`, with three new outbox jobs (`ledger_register`, `ledger_guardians`, `authority_share`).
- **Hooks:** app start (register and sync), adding or removing a guardian (re-sync), and after anchoring (share).
- **Rules:**
  - demo builds only (`--dart-define=DEMO_AUTHORITY=true`) and `LEDGER=fabric`;
  - the opt-in applies only to recordings made after it;
  - single-guardian recordings are never shared;
  - guardians who haven't registered are added later;
  - the version number is read back from the ledger;
  - retries are harmless.
- **Checks:**
  - 12 unit tests (`test/authority_service_test.dart`), including the police piece plus a guardian piece decrypting the clip;
  - a live run with the app's services against the real gateway (`test/authority_app_live_test.dart`) passed;
  - `check-authority-share.sh` passed: the officer unsealed exactly the app's piece (x=2), the Auditor has no copy, and block 115 holds only a hash;
  - full suite: 112 pass.
- **Still for the redesign:** the opt-in switch with the "SIMULATED / call 112" notice on the Guardians screen. Until then, `AuthorityService.setShareWithAuthority(true)` turns it on.
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

### Step 5. App part of approvals (9c), logic first — done 14-10-2026 (screens come with the redesign)
**Result:**
- **Code:** in `authority_service.dart`:
  - `openRequestsForMyRecordings()` (victim);
  - `openRequestsIGuard()` (guardian; only clips this phone holds its own piece of);
  - `approveRequest(id)`, which queues the new outbox job `authority_release`.
  - Gateway calls `listAccessRequests`, `getAccessRequest` and `releaseShare` are in `fabric_ledger_service.dart`.
- **Rules:**
  - the victim releases a fresh piece (new index from the record's counter);
  - a guardian re-locks the piece the victim gave them;
  - the locked piece is saved until the release succeeds, so a retry sends the identical piece, which the gateway needs to finish a half-done release;
  - a request already released elsewhere sends nothing;
  - a revoked authority is refused.
- **Checks:**
  - 7 new unit tests (19 in `test/authority_service_test.dart`);
  - a live run, `test/release_app_live_test.dart`, passed with the officer working through the real portal: a guardian approved one clip and the victim another, the portal opened both with every check passing and the video byte-identical, and each audit trail reads `shared, requested, released, opened`;
  - full suite: 119 pass.
- **Plan as written:**
- **What:**
  1. **Victim side:** list access requests from the police for my recordings, and approve one. Approving makes a new key piece, locks it to the police's key and releases it through the gateway.
  2. **Guardian side:** "Release my piece", which re-locks the guardian's own piece to the police's key and releases it.
  3. Both go through the outbox, so they retry when offline.
- **Why:** completes the approval flow the officer portal already expects.
- **The screens** ("Access requests", "Release my piece") are built in the redesign.
- **Done when:** a live Dart run of the whole story passes using the app's services: share → officer requests in the portal → victim *or* guardian releases → the portal opens the clip, with all checks passing and the audit trail showing every step.

### Step 5b. Disguise mode — done 14-10-2026 (the settings switch comes with the redesign)
**Result:**
- **Code:**
  - `AndroidManifest.xml`: two launcher faces. `.SakshyaFace` is a tiny activity that forwards to MainActivity, because Flutter's tooling only launches a real `<activity>`. `.CalculatorFace` is an alias, off by default, with its own label and a graphite "+ − × =" icon.
  - `MainActivity.kt`: method channel `in.sakshya/disguise` (`getLauncherFace`, `setLauncherFace`); it turns the new face on before turning the old one off. `FLAG_SECURE` is set in release builds only, so the team can still take debug screenshots.
  - `lib/logic/decoy_calculator.dart`: a working calculator (× ÷ before + −, %, ⌫, "Can't divide by 0").
  - `lib/core/disguise_service.dart`: the setting, saved in Hive and needing a registered PIN; start-up repairs the launcher if it doesn't match.
  - `lib/presentation/calculator_screen.dart` and `disguise_gate.dart`: the gate sits above the navigator and re-locks whenever the app goes to the background. The app keeps running underneath, so "112 =" records at once.
  - Debug builds have a "Debug: Disguise as Calculator" button on the home screen until the redesign.
- **Rules:**
  - a code counts only as a whole entry on its own ("112 =", or a 4–6 digit "PIN =", leading zeros kept);
  - the screen shows the number like any sum;
  - the PIN check (Argon2id) runs in the background, so the calculator never stalls.
- **Checks:**
  - 23 new unit and widget tests: the calculator, the codes, PIN unlock and wrong PIN, re-locking, quick SOS, and switching the face;
  - full suite: 142 pass;
  - `aapt` on the release APK lists both entries (Sakshya on, Calculator off by default);
  - on the Pixel 6 emulator (Android 13):
    - the switch replaced Sakshya with "Calculator" in the app drawer;
    - the start-up splash and the recent-apps card used the calculator icon;
    - "7×6=" gave 42;
    - "112 =" started a recording behind the calculator;
    - PIN then = unlocked;
    - leaving and coming back re-locked;
    - switching back restored Sakshya;
    - the release build's window is `SECURE` (screenshots refused).
- **Found on the emulator, for step 9 and the user notes:**
  - switching faces closes the app (Android removes a task whose launcher entry is switched off);
  - Android 12+ shows the green microphone dot while AI monitoring listens, even under the calculator. That can't be hidden, and a calculator using the microphone may look odd;
  - with no guardians, saving a clip fails ("Recording Save Failed") for the normal SOS button too, so not because of disguise mode. On phones with guardians this is checked in step 9;
  - after the 45-second auto-stop, the status line keeps saying "RECORDING EVIDENCE..." (old behaviour; to fix in the redesign).
- **Plan as written:**
**Decided 14-10-2026:** Calculator is the only disguise, with "112 then =" as a quick SOS. Prototype: the "App icon and disguise" screens.
- **What:**
  - two launcher "faces" in `AndroidManifest.xml` (`<activity-alias>`): Sakshya, and Calculator with its own icon and label;
  - a small Kotlin method channel that enables exactly one face (`PackageManager.setComponentEnabledSetting`);
  - the app opens on a working decoy calculator when started through the Calculator face;
  - **PIN then =** unlocks the full app (the PIN set at registration);
  - **112 then =** starts an SOS recording at once, without unlocking;
  - the app preview is hidden in recent apps (`FLAG_SECURE`, which also blocks screenshots of Sakshya).
- **Why:** Android 10+ can't hide an app completely, so the app looks like something ordinary instead. A real, working calculator survives someone opening it, unlike a fake brand app, which would also break Play Store impersonation rules.
- **Limits to explain to users:** the real name still shows in the phone's Settings → Apps list. The icon can take a few seconds to switch, and some launchers drop it from the home screen (add it back from the app drawer). In disguise mode the full app needs the PIN; quick SOS doesn't.
- **Done when:**
  - unit tests cover the calculator, the PIN unlock, quick SOS, and switching the face;
  - a release build lists both launcher entries (checked with `aapt`);
  - on an emulator, switching the face changes the launcher icon and name. Real phones are checked in step 9.

### Step 6. Decide the open questions (decisions from you, no coding)
These were left open in earlier docs. Each needs a yes or no before the demo:
1. **Recovery code (Option 1):** build it, or present it as future work? Without it, a victim with no guardians who loses her phone can't recover her clips.
   - **Decided 14-10-2026: build it. Built the same day.**
   - **Code:**
     - `lib/core/recovery_code.dart`: 128 random bits shown as six groups of five (Crockford base32) with a 22-bit checksum, so any one-character typo is refused. Each key comes from its own HKDF label: Ed25519, X25519, secp256k1, and an "evidence root". Each clip's key is HKDF(evidence root, the clip's SHA-256), which the ledger records.
     - `IdentityService`: a new phone's keys come from the secret. The code is kept only until confirmed. `restoreFromRecoveryCode` rebuilds the same node ID and keys. `clipKeyFor` gives the clip key.
     - `EvidenceEncryptor`: uses that key for new clips; `decryptWithRecoveredKey` opens a clip from its ciphertext alone and checks the hash.
     - `lib/core/recovery_service.dart`: restore lists the identity's clips from the ledger (`/history`, which includes clips a guardian anchored on the victim's behalf). Each comes back as a "restored" record that My Evidence fetches from IPFS and plays.
     - After a restore, guardian sync is paused until a guardian is paired again, so the empty new phone doesn't wipe the guardian list on the ledger.
     - Screens (plain, restyled in step 7): "Your recovery code" after registration (type the last group to confirm), "Lost your phone? Restore with recovery code" on the registration screen, and restored clips in My Evidence.
   - **Checks:**
     - 15 new tests (`test/recovery_test.dart`): code format and typo detection, the same identity on a second phone, mistyped and wrong codes, phones from before recovery codes keep random keys, restore and open from IPFS, a changed IPFS file refused, an unreachable ledger reported, guardian-sync pause, the code screen;
     - live run `test/recovery_live_test.dart` against Fabric: a phone with no guardians anchored two clips; a new phone with only the code got the same node ID back, found both on the ledger and opened both from the IPFS stand-in, byte for byte;
     - full suite: 157 pass.
   - **Terms (decision doc section 4), and how they apply now:**
     - phones must be set up fresh: they will be anyway in step 9 (new app ID);
     - only clips recorded after this change are recoverable;
     - the ledger keeps its records (Fabric volumes, never `network.sh down`);
     - anyone with the code can open the clips, so keep it like a seed phrase;
     - the restored phone starts with no guardians; pair them again.
2. **Cloud deployment:** keep the network and gateway on the laptop for the demo (both phones on the same Wi-Fi), or move them to a cloud server so the demo doesn't depend on the laptop? If cloud, step 8 is added and needs your cloud account.
   - **Decided 15-10-2026: laptop + tunnel now (option A), cloud later as an upgrade (option B), with the laptop kept as the fallback.** Details in step 8.
   - **Options considered:**
     - Azure for Students: $100 credit, no card, college email, 12 months;
     - Google Cloud trial: $300, card, 90 days;
     - Oracle Always Free: no expiry, but ARM and often out of capacity in India;
     - AWS free tier: 1 GB RAM, too small for Fabric.

     Free app hosts (Render, Railway) can't run Fabric. B and C both outlast the 15 days left before submission.
   - **Why this order:** the laptop setup already passed every live test. A tunnel makes it reachable over mobile data, so college Wi-Fi blocking phone-to-laptop traffic no longer matters. The cloud is added early (around days 3–7, not the last days) so its problems surface with time to fix them. On demo day: use the cloud if it's healthy, otherwise switch to the laptop in about a minute.
3. **AI false triggers:** keep as a known limitation for the presentation, or run the one-afternoon experiment from `DOCS/08-10-2026 AI false trigger analysis.md` (step 1 there) first?

### Step 6c. App icon (decision deferred, 15-10-2026)
- **The tag placeholder stays** until you give the final icon.
- **Draft:** a solid "S" mark (flame-like top, leaf at the lower left, even gap), redrawn as a vector from your reference images. The second, solid option was preferred over the purple gradient, because a flat mark stays sharp at small sizes and works as an Android 13+ themed icon.
- **Colours: not decided yet.**
- **Draft files** (outside git): `D:/Justice-Chain/icon_drafts/`, with `sakshya-icon-preview.png` and `.svg`, `make_icon.js` (regenerates the mark in any colours) and `mark_paths.json`.
- **Note:** the reference mock-ups said "Sakshyam"; the app's name is **Sakshya**.
- **When the final icon arrives:** adaptive icon (foreground, background, monochrome), round icon, and legacy PNG sizes, then check on the emulator. About 30 minutes.

### Step 6b. Background listening (foreground service). Do after the AI false-trigger fix; plan first, then code
**Found 14-10-2026 during AI experiment 2 on the Vivo:** when the phone is locked or the app isn't on screen, Android stops giving the app the microphone, so **automatic detection only works while Sakshya is open**. The SOS button and "112 =" are unaffected (they need the app open anyway).
- **What:**
  - **A foreground service:** a small Kotlin service declared as type `microphone` (and `camera`), with the matching permissions in `AndroidManifest.xml` (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`, `POST_NOTIFICATIONS`) and a notification channel. Android lets such a service keep running in the background as long as it shows a **permanent notification** (e.g. "Sakshya is protecting you").
  - **Start and stop:** the service is started when monitoring starts, which happens while the app is on screen. Android requires that: a microphone service can't be started from the background. It stops when the user turns protection off. Our existing Dart AI code then keeps listening with the screen off.
  - **Recording while locked: video, recorded by the service itself (decided 15-10-2026).** The service is declared as type `camera|microphone` and started while the app is on screen. It then keeps camera and microphone access in the background and when the phone is locked: Android documents the camera type as "continue to access the camera from the background". On a trigger the service records video itself with CameraX, in Kotlin, with **no window, no preview and no screen wake**. Then it hands the file to the existing seal-and-upload path.
    - The Flutter camera plugin can't do this: it needs the app on screen. So the background recording is a small native recorder; the on-screen SOS keeps using the plugin.
    - **Audio-only fallback:** if the camera can't be opened (another app is using it, the camera privacy switch is off, or an OEM blocks it), record audio, so there is still evidence.
    - **Rejected: popping the app open in a small or picture-in-picture window on a trigger.**
      - Android blocks apps from opening screens from the background, unless the user grants "Display over other apps", which on Android 15 also needs a visible overlay.
      - Picture-in-picture can only start from a screen already open.
      - Over the lock screen it would have to turn the screen on, which is the opposite of discreet.
      - The service approach records video without any of this.
    - **What stays visible:** the permanent notification, and Android 12+'s green camera and microphone dots while recording. Neither can be hidden.
    - **Vivo and Samsung battery managers** may still kill background services. The app must guide the user to allow it: Vivo "Allow background activity / high background power use"; Samsung "Never sleeping apps". Check on both phones in step 9.
  - **Disguise mode:** the permanent notification would give the app away. In disguise mode it needs neutral wording and icon (e.g. "Calculator" or "Running"). **A design decision for you.**
  - **Decided 15-10-2026 (microphone dot): a user switch, "Keep listening while disguised", on by default.** Android 12+ shows a green dot whenever the microphone is in use, and apps can't hide it. With the switch on, automatic detection keeps working under the calculator (and the dot shows). With it off, listening stops while disguised: no dot, and only "112 =" or the SOS button records. The same switch also controls the background service's notification. The switch's screen comes with the redesign (step 7).
  - **If the app is swiped away from recent apps:** today the AI stops, because the Flutter engine belongs to the screen. Keep the engine alive in the service (a cached `FlutterEngine` owned by the service), so listening, recording and upload go on until the user turns protection off.
  - **Battery:** continuous listening drains battery. Measure the drain per hour on both phones and report it.
- **Why after the AI fix:** today the model false-triggers about 100 times an hour of ordinary talking (experiment 1). Listening all day in the background would mean dozens of unwanted recordings and uploads per day.
- **Done when:**
  - with the phone locked, a test distress sound is detected, and a **video** recording (audio-only if the camera is unavailable) is saved and uploaded;
  - the same works after the app has been swiped away from recent apps;
  - the notification shows the right wording in normal and disguise mode;
  - battery drain per hour is measured on both phones;
  - unit tests are green. The real-phone checks are part of step 9.

### Step 7. UI redesign (after you approve the preview)
- **What:** build the approved design in Flutter, including the new screens for steps 4 and 5: the police opt-in, "Access requests" and "Release my piece".
- **Why after 4–5:** those screens are designed and built once, in the new style.
- **Done when:**
  - analyzer and tests are green;
  - a release build succeeds;
  - screenshots from an emulator match the preview. The real-phone check is in step 9.

### Step 8. Reachable gateway: laptop + tunnel now (8a), cloud later (8b)
**Decided 15-10-2026** (step 6, question 2).

**8a. Laptop + ngrok tunnel. Do first.**
- **What:**
  - **The tunnel:** an ngrok tunnel (free plan, one **fixed** address such as `xyz.ngrok-free.app`) in front of the gateway on the laptop. `GATEWAY_URL` in `.env` points at that address, so the phones reach the gateway over mobile data, with no shared Wi-Fi needed.
  - **A gateway password:** an API key the app sends with every request. The gateway has no login today; signatures prevent forgery, but anyone who can reach it can call it.
  - **The officer portal stays on the laptop, localhost only.** It holds the simulated police key and is never exposed.
- **Needs from you:**
  - a free ngrok account, with its free static domain claimed;
  - the authtoken saved in a git-ignored file. **Never paste it in the chat.**
- **Done when:** the live Dart tests pass through the tunnel address, and a phone on mobile data (Wi-Fi off) anchors a clip.

**8b. Cloud machine. An optional upgrade, around days 3–7 before submission.**
- **What:**
  - the same Fabric network and gateway on a cloud VM (Azure for Students, or Google Cloud's trial), with about 8 GB RAM and Docker;
  - the ngrok agent runs on the VM instead of the laptop, so the **same fixed address** now points at the cloud and the phones need no rebuild;
  - the portal stays on the laptop and reaches the cloud network's SimPolice peer through an SSH tunnel.
- **Fallback:** stop the tunnel on the VM and start it on the laptop. The laptop network must be kept intact (never `network.sh down`).
- **Caveat:** each setup has its **own ledger**. Clips recorded on one don't exist on the other, so don't switch in the middle of a demo story; the recovery-code restore must use the ledger the clips were recorded on.
- **Needs from you:** the cloud account (Azure for Students with the college email, or a Google Cloud trial).
- **Done when:**
  - the live Dart tests and failure tests pass against the cloud;
  - the portal opens a clip through the SSH tunnel;
  - the switch back to the laptop has been practised once.

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
7. **Disguise:**
   - switch to Calculator on both phones (the Vivo and Samsung launchers behave differently);
   - check recent apps show no preview;
   - PIN then = opens the app;
   - 112 then = starts SOS without unlocking;
   - switch back to Sakshya.
8. **Background listening (step 6b):** lock the phone, play a test distress sound, and check a recording is made and uploaded. Check the notification wording in normal and disguise mode, and measure battery drain.
9. **Redesign on real hardware:** screenshots of every screen, checking for layout or text issues on both phones.

Then record the results in a device test log, commit, and tick 4c, 8d, 9c, 10b and Step 12 in the design-doc checklist.
