# Sentinel Build Log: 04-10-2026

Branch: `local-blockchain--code` (from `ipfs-changes`). Follows the 02-10-2026 log and the blueprint's build order.

## Status key

- **Committed and pushed**: in commit `2507c1dc` on `origin/local-blockchain--code`.
- **Written, not tested, not committed**: code exists in the working tree only. The analyzer / editor shows no compile errors, but no tests were run and nothing was tried on a device.

---

## 1. Git: checkpoint of the 02-10 work (committed and pushed)

- Created branch `local-blockchain--code`, committed all 33 files from the 02-10 log, and pushed it (`2507c1dc`).
- Checked first that `.env` is gitignored and that no keys are hardcoded (Pinata, Hardhat and device keys all come from `.env` or secure storage).
- PR #3 was opened by the user against `main`. It is not merged.
- Open item: `DOCS/Justice-Chain-Sentinel-Technical-Handoff.pdf` was flagged for line-ending conversion. Check it still opens on GitHub; if not, add a `.gitattributes` marking PDFs as binary.
- Everything below this line is **not committed**.

## 2. Pinata upload timeout and clear errors (written, partly tested)

Fixes the upload hang from the 02-10 log (a network silently dropping large POSTs).

- `lib/core/pinata_service.dart`: rewritten. Timeout is 30 s plus 1 s per 256 KB of file, and a timeout closes the connection. Failures now throw `PinataUploadException` with a readable reason (timed out, no connection, HTTP status, missing JWT) instead of returning `null`.
- `lib/core/evidence_vault_service.dart`: status line now shows the failure reason.
- `lib/main.dart`: debug test-upload handles the new exception.
- `test/pinata_service_test.dart`: new, 3 tests.
- Verified: full Flutter suite passed (36 tests) at this point. Not verified on a device or on the Wi-Fi network that hung.

## 3. Phase 2 remainder: outbox, Shamir 2-of-3, late guardian shares (written, not tested)

- `lib/core/shamir.dart` (new): Shamir secret sharing over GF(256).
- `lib/core/evidence_encryptor.dart`:
  - Guardians now get one Shamir share each, sealed to their X25519 key, instead of a full copy of the incident key. `guardianQuorum = 2`.
  - Added `issueGuardianShare`, `unsealGuardianShare`, `recoverIncidentKey`, `decryptFileWithShares`.
  - Removed `unwrapIncidentKeyFromGuardian` and `decryptFileAsGuardian`.
  - Shares are derived from the incident key, so a share issued later combines with ones issued at recording time.
- `lib/core/outbox_service.dart` (new): Hive-backed retry queue (30 s backoff up to 1 h, 20 attempts), run at startup, every minute, on network reconnect and when a guardian connects.
- `lib/core/evidence_vault_service.dart`: rewritten around the outbox. Upload and anchor are retryable jobs, and the anchor job checks the chain first so an anchor that already landed doesn't retry forever. Added `issueMissingGuardianShares` (also strips the old full-key wraps) and `resumePendingWork`.
- `lib/logic/guardian_manager.dart`: pairing a guardian now issues shares for earlier incidents and queues relays.
- `lib/core/app_services.dart`, `lib/main.dart`: open the new Hive boxes and start background work after `.env` loads.
- `test/evidence_encryptor_test.dart`: guardian tests rewritten for the quorum API.
- Gaps: no unit tests for `shamir.dart` or the outbox. With one guardian paired, nobody can decrypt (2 are needed).

## 4. Phase 4: offline mesh relay (written, not tested)

- `lib/core/mesh_service.dart`: rewritten.
  - Victim advertises while recording and while any clip or share is waiting. Guardian discovers while the app is open and connects only to paired node IDs.
  - A relayed clip is sent as a file plus an Ed25519-signed manifest carrying the victim's pre-signed anchor signature. The guardian keeps the file only if the sender matches the connected peer, the signature verifies against the key saved at pairing, and the ciphertext hash matches.
  - Guardian sends an acknowledgement; the victim resends after 3 minutes with no ack. Android 11+ content URIs are handled.
  - Key shares are delivered over the same link, accepted only from the peer on that connection.
- `lib/core/anchoring_service.dart`: added `signAnchor` and an optional `signatureHex`, so a guardian can anchor with the victim's signature.
- `lib/core/outbox_service.dart`: new job types `mesh_relay` and `relay_upload`; advertising starts and stops with pending mesh work.
- `lib/core/evidence_vault_service.dart`: queues relays to every paired guardian; `uploadRelayedClip` uploads and anchors on the victim's behalf, skipping the anchor if it already exists.
- `lib/core/emergency_controller.dart`: starts advertising when recording starts.
- `lib/presentation/home_screen.dart`: requests Bluetooth and nearby-Wi-Fi permissions and starts discovery.
- `android/app/src/main/AndroidManifest.xml`: added `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`.
- Departure from the blueprint: the manifest is sent right after the file transfer starts (it must name the transfer ID), not strictly before. The guardian still never keeps a file without a verified manifest.
- Needs two phones, paired both ways, to test the blueprint's airplane-mode scenario.

## 5. Phase 5: guardian playback and verification (written, not tested)

- `lib/core/guardian_evidence_service.dart` (new): lists incidents a guardian holds; `openAndVerify` rebuilds the key from 2 shares, uses the relayed copy or downloads from IPFS (`IPFS_GATEWAY` in `.env`, default Pinata gateway), decrypts, then checks: content hash, victim's device signature, on-chain CID, and on-chain signer vs the address saved at pairing.
- `lib/core/anchoring_service.dart`: added the `EvidenceAnchored` event to the ABI and `findAnchorBlock`, which gives the "anchored in block N at time T" text.
- `lib/presentation/guardian_evidence_screen.dart` (new): incident list with key-piece count, **Open & verify**, and **Send my piece**.
- `lib/core/mesh_service.dart` and `lib/core/evidence_encryptor.dart`: added `forwardShare` and `sealShare` so one guardian can pass their share to a co-guardian (explicit tap, delivered over the mesh).
- `lib/presentation/evidence_player_screen.dart`: now takes a plaintext loader and shows the verification panel. `evidence_viewer_screen.dart` updated to match.
- `lib/presentation/guardian_scanner_screen.dart`, `lib/logic/guardian_manager.dart`: pairing now saves the contact's `anchoring_address`.
- `lib/presentation/home_screen.dart`: new **Guardian Evidence** button.
- Gaps: no victim-approval or 72-hour release rule yet (two guardians agreeing is enough); guardians must also be paired with each other to forward shares; the victim's "My Evidence" still plays the local file.

## Known cross-cutting gaps

- Local `.enc` files are never deleted after upload and anchor (blueprint wants deletion once both are confirmed).
- The funded Hardhat submitter key is still read from `.env` (local demo only, per the blueprint).
- Existing records may carry the old `guardianWrappedKeys` field until the next app start strips it.

## Not done yet

| Item | Status |
| --- | --- |
| Tests for Phases 2 (rest), 4, 5; device checks for all of them | Not run |
| Commit and push of sections 2 to 5 | Not done |
| Phase 6: 15 s segments, Android foreground service | Not started |
| Phase 7: public testnet (Polygon Amoy) | Not started |
| Phase 8: Hyperledger Fabric | Parked |

## Suggested next steps

1. Run `flutter analyze` and `flutter test`, and add unit tests for `shamir.dart` and the outbox.
2. Commit and push sections 2 to 5.
3. Two-phone test: pair both ways, airplane mode with Bluetooth and Wi-Fi on, record, confirm the relay, then go online and confirm IPFS and on-chain.
4. Then Phase 6.
