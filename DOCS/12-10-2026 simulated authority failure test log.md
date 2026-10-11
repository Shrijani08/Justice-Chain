# Simulated authority: failure test log (12-10-2026)

Step 12 of `DOCS/08-10-2026 simulated authority guardian on Fabric design.md`. Every misuse the design lists was tried on the live network and refused. **21 checks, all passed.**

## What was tested

- **Network:** `evidence-channel` with JusticeChainOrg (Org1), the Auditor (Org2, SIMULATED label) and SimPolice (SIMULATED). Chaincode `justiceledger` 1.5, sequence 7.
- **Test data:** test clips, requests and releases left on the ledger by the Step 8–10 live runs. All test keys, no real evidence.
- **Scripts (re-runnable):**
  - Ledger side, in WSL: `fabric/network/failure-tests.sh` (17 checks).
  - Portal side, in Git Bash with the portal and the local IPFS stand-in running: `fabric/portal/failure-tests.sh` (4 checks).

## Results

| # | Case from the design | What was tried | Result |
|---|---|---|---|
| 1a | Wrong role | supervisor1 requests access | Refused: only officers may |
| 1b | Wrong role | officer1 reads the audit trail | Refused: supervisors, JusticeChain and the Auditor only |
| 1c | Wrong role | JusticeChain's ordinary user registers an authority | Refused: admins of Org1 or Org2 only |
| 2a | Auditor reading the police collection | The Auditor's admin asks for SimPolice's key piece | Refused: officers only |
| 2b | Auditor reading the police collection | officer1 asks the Auditor's **peer** for the piece | Refused by Fabric: "private data matching public hash version is not available"; the Auditor's peer has no copy |
| 3a | Police with one piece | officer1 holds 1 piece of a clip nobody released | 1 of 2 needed, so the key can't be rebuilt |
| 3b | Police with one piece | officer1 records "opened" for that clip | Refused: no released request |
| 8a | Police with one piece | "Open and verify" in the portal for that clip | Stops at "Enough pieces to open: 1 of 2 pieces held" |
| 4a | Self-approval | officer1 releases a piece for their own request | Refused: only JusticeChain's gateway submits releases, with a victim or guardian signature |
| 4b | Self-approval | A correctly signed release endorsed by JusticeChain + SimPolice, **without the Auditor** | Invalidated by Fabric: `ENDORSEMENT_POLICY_FAILURE` |
| 5a | Release without a valid signature | The guardian's signature reused for a different piece | Refused: not signed by the releaser |
| 5b | Release without a valid signature | A made-up signature | Refused: signature could not be recovered |
| 5c | Release without a valid signature | Request 2 after all the attempts above | Still open |
| 6a | SimPolice removed | JusticeChain and the Auditor revoke SimPolice in the registry | Committed |
| 6b | SimPolice removed | officer1 requests access after the revoke | Refused: not an active authority |
| 6c | SimPolice removed | officer1 reads a key piece after the revoke | Refused |
| 6d | SimPolice removed | The registry entry | Shows `revoked: true`; kept for the audit trail |
| 6e | SimPolice removed | Registered again with the same desk key | officer1 can read again; network restored |
| 7a | Tampered IPFS file | One byte flipped in the encrypted clip, then "Open and verify" | Stops at "Clip decrypted: the rebuilt key does not open this file" |
| 7b | Tampered IPFS file | The audit trail after that failed open | No "opened" entry added |
| 7c | Tampered IPFS file | Original file restored, opened again | All 9 checks pass |

## Notes

- **"SimPolice removed" means a registry revoke**, not removing SimPolice from the channel configuration. A revoke is enough to show that its officers' transactions are refused, and it can be undone in one step. Removing an organisation from the channel is a channel config update that also affects its private collection, so it wasn't done on the demo network.
- **Earlier step checks cover the rest of the design's checks:**
  - Step 8: the block holds only the hash of a shared piece.
  - Step 9: the officer rebuilds the right key, and the audit trail shows every step.
  - Step 10: a clip decrypted in the portal is byte-identical to the recording.
- **Still to do with phones:** the same flow starting from a clip recorded on a phone and uploaded to IPFS through Pinata (Step 10b). The app screens for sharing with the authority and releasing a piece (8d, 9c) come in the same session.
