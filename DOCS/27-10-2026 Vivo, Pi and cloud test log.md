# Test log: Vivo, Pi and cloud session (26–27 Oct 2026, 00:12–01:40 IST)

Setup: ledger, gateway, portal and ngrok tunnel on the Azure VM `sakshya-ledger`
(Korea Central). Owner phone: Vivo V2239, debug APK from branch `judge-fixes`
(node `c99c9192493dda91`). SOS device: Raspberry Pi 4 (node `63c11093d0c34141`) on
the Vivo hotspot. Only the Vivo was available; tests that need the guardian phones
are listed at the end.

## Results

| # | Test | Result | Evidence |
|---|------|--------|----------|
| 1 | PIN lock: wrong PIN 5×, 30 s block, right PIN opens | Pass | Checked on the phone |
| 1b | Leaving the app locks the evidence again | **Failed, fixed, passed** | Commit `48fd3534`; passed on the phone after the fix |
| 2 | SOS recording works without the PIN | Pass | Checked on the phone |
| 2b | Recording screen timer counts up | **Failed (stuck at 00:00), fixed, passed** | Commit `48fd3534`; passed on the phone after the fix |
| 3 | Phone upload through a one-time gateway upload URL | Pass | Gateway: `POST /upload-url` 200 → `POST /anchor` 200 at 00:25 and 00:43 |
| 4 | Offline recovery: recorded in airplane mode, back online after 20 min | Pass | Offline 00:46–01:06; the app asked for an upload URL by itself at 01:07:08; anchored 01:07:50 |
| 5 | Police flow: share → request → release → open | Pass | Clip `3a377bf3…`; audit trail in blocks 341 (share), 342 (request), 343 (release), 345 (opened) |
| 6 | Gateway API key rotation | Pass | New key: old key gets 401, new key gets 200; the Pi checked in with 200 |
| 7 | Pi SOS clip: record → seal → IPFS → Fabric → guardian pieces | Pass | Clip `771cd883…`, CID `bafybeicvoyserr7efc6jybrmx63vuxvqtykmblqrqqs2ltpd4yxo3dixyi`, tx `5bc63595…`; pieces to `6d7eebac…` and `88b0d0cf…`; the device deleted its copy |

Also done in this session: the Pinata key was rotated (new key can only upload
files; the old key is revoked and returns 401/403), and two-step verification was
turned on for the Pinata account.

## Bugs found and fixed (commit `48fd3534`)

1. **Recording timer showed 00:00 for the whole recording.** The 500 ms clock was a
   lazy `late final` field that nothing read until `dispose`, so it never started.
   It is now started in `initState`. A widget test checks that the clock moves.
2. **The evidence stayed unlocked after leaving the app from a non-evidence screen.**
   Only `PinGate` locked on pause, and only while it was on screen. An app-wide
   observer (`EvidenceLock.lockWhenAppLeaves`) now locks from any screen.
   A test covers it.

All 274 app tests pass after the fixes.

## Observations (not fixed)

- **Pi reset on the first SOS try (01:30).** The user touched a jumper wire while
  pressing the button. The retry, without touching the wires, passed. The Pi runs
  from a phone charger, which is below the official 5 V / 3 A; watch for resets.
- **ngrok drops a connection now and then.** Seen on the app's key-piece mailbox
  check at start-up ("Connection closed before full header was received") and on
  the Pi's setup check ("Connection aborted"). The request never reaches the
  gateway. Both retry by themselves; no data was lost.
- An unhandled `PlatformException` from `CameraApi.dispose` appears in the app log.
  No visible effect.
- The Vivo's USB debugging connection dropped several times. This affected only
  log capture, not the tests.
- The Pi's status LED stays lit after shutdown until the power is removed. This is
  normal: GPIO pins keep their last state.

## Still to test

- Opening a clip with two guardians (needs the Samsung and the OnePlus; they hold
  pieces of Pi clip `771cd883…`).
- AI scream tests 2–5 on the Vivo, then on the Samsung.
- Install the new APKs on the Samsung and the OnePlus. Their old builds can no
  longer upload, because the old Pinata and gateway keys are revoked.
