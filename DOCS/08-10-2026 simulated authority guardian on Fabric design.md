# Simulated Authority Guardian on Hyperledger Fabric: Design (08-10-2026)

**Status:** in progress (see the checklist in section 9). **Decided 08-10-2026:** police only as an official key holder; no legal-aid organisation. Org2 stays in the network as a neutral **Auditor (SIMULATED)** with no key piece. This expands **Option 3 (Organisation as a guardian)** from `08-10-2026 guardian quorum and recovery decision.md` for the academic prototype: a **simulated** authority now, a real partner later.

## 1. Can we use a mock police authority? Yes, with guardrails

Simulating an authority is a normal and acceptable way to demonstrate an inter-organisation workflow in an academic prototype. The rules below keep it honest and safe.

### Hard requirements (non-negotiable)

1. **Plainly fictional name.** e.g. **"Demo Police Authority (SIMULATED)"**, MSP ID `SimPoliceMSP`. Do not use any real force, city, state or department name, emblem, uniform colours, badge/FIR number format or helpline number.
2. **"SIMULATED" is everywhere the identity appears:** the MSP name, the CA certificate subject (`O=SimPolice (SIMULATED)`), the officer portal header/watermark, and the app's guardian list entry.
3. **Demo build only.** Justice-Chain is an app for real victims. The biggest real-world harm would be a real user believing they have reported to police when they have not. So:
   - the "Authority guardian" option exists **only behind a demo build flag** (e.g. `--dart-define=DEMO_AUTHORITY=true`), never in a normal build;
   - wherever it appears, the app says: **"Demonstration only. No real police are contacted. In an emergency call 112."**
4. **Synthetic data only** in the officer portal: staged recordings by team members who consented, never footage from the test phones of real people or real incidents.
5. **Disclose it** in the report and presentation: "The police authority in this demonstration is a simulated organisation created by the project team. It is not affiliated with, endorsed by or connected to any real police or legal authority."

### Prototype vs real deployment

| Aspect | Academic prototype (simulated) | Real deployment (would need) |
|---|---|---|
| Who runs the authority node | The team, on the same laptop / Docker host | The authority itself, on its own infrastructure |
| How the org is admitted | Channel config update signed by the other (team-run) org admins | Same mechanism, but backed by a signed agreement (MoU) with the real authority |
| Identity root | Self-generated Fabric CA for `SimPoliceMSP` | Authority-operated CA or government-issued PKI |
| Officer identities | Team members enrolled with `role=officer` | Real officers, enrolled and revoked by the authority's own admin |
| Legal basis for access | None (demonstration) | Requires legal review: lawful basis for access, electronic-evidence admissibility/certification, data-protection law, retention rules |
| Data | Synthetic, consented recordings | Real victim evidence |
| Victim-facing wording | "Demonstration only, no police contacted" | Approved wording agreed with the authority |

The "would need" column lists items **requiring legal review**; we deliberately don't cite specific statutes in the report unless someone has verified them.

## 2. Two layers of control (the key idea)

| Layer | Controls | Mechanism |
|---|---|---|
| **Fabric (permissioned ledger)** | Who may **write and read records**, and an audit trail of every access | MSPs, certificate attributes (ABAC), endorsement policies, private data collections |
| **Cryptography (already in the app)** | Who can **actually decrypt** a recording | AES-GCM per clip + Shamir 2-of-N key shares |

Fabric alone cannot keep a recording secret: chaincode runs on every endorsing peer and anyone with ledger access sees its inputs. So **the video and keys never go on the ledger.** The ledger holds hashes, IPFS CIDs, consent and access records. Decryption still requires a quorum of Shamir shares, exactly as today.

**The simulated authority holds one Shamir share.** With a threshold of 2, it **cannot open evidence alone**: it needs a second share, and only the victim or a personal guardian can provide one (see section 5).

## 3. Network architecture

```
                         ┌──────────────────── Fabric channel: evidence-channel ────────────────────┐
                         │                                                                           │
 Victim phone ──HTTPS──▶ │  JusticeChainOrg (Org1)    SimPoliceOrg (SIMULATED)   Auditor (Org2,      │
 (Flutter app,           │  peer0 + CA                peer0 + CA                 SIMULATED label)    │
  device keys)           │  Gateway API (Node)        Officer portal (web)       peer0 + CA only     │
                         │                                                                           │
 Guardian phones         │                OrdererOrg: 1 Raft orderer (prototype)                     │
 (mesh, as today)        └───────────────────────────────────────────────────────────────────────────┘
                                         │
                          IPFS / Pinata (encrypted clips, unchanged)
```

| Organisation | Role in the demo | Fabric components |
|---|---|---|
| **JusticeChainOrg** (`Org1MSP`) | Operates the service: receives anchors from phones | peer0, CA, **Gateway API** |
| **SimPoliceOrg (SIMULATED)** (`SimPoliceMSP`) | Authority guardian: holds one share, requests access, investigates | peer0, CA, officer portal |
| **Auditor (SIMULATED)** (`Org2MSP`) | Neutral observer: endorses writes so JusticeChainOrg can't change records on its own, and co-endorses approvals and key releases. Holds **no** key piece and has no portal | peer0, CA |
| **OrdererOrg** | Ordering service | 1 Raft orderer (3 in a real deployment) |

"Auditor (SIMULATED)" is a **label in our docs and slides only**. The organisation is still the test-network's `Org2MSP` and its certificates say `Org2`; don't claim they say SIMULATED. Renaming it would mean rebuilding the network, which isn't worth it.

### Why phones are clients, not peers

- There is no maintained Fabric SDK for Dart/Flutter. Phones also can't run peers.
- JusticeChainOrg runs a small **Gateway API** (Node.js using `@hyperledger/fabric-gateway`). The app sends it requests over HTTPS.
- **The victim is not a Fabric identity.** The app already signs each manifest with the device key. The gateway submits the transaction with its own identity and puts the victim's signature in the payload, and **the chaincode verifies the device signature itself**. This mirrors `JusticeLedger.sol`, where the contract recovers the victim as signer whoever submits. A compromised gateway therefore cannot forge a victim's anchor or consent.
- Personal guardians stay on the mesh, as today. They need no Fabric identity.

### Keep both ledgers behind one interface

Don't replace `AnchoringService` outright. Introduce a `LedgerService` interface with two implementations:

- `EvmLedgerService`: today's Hardhat / Phase 7 Polygon Amoy code;
- `FabricLedgerService`: calls the Gateway API.

The demo can switch between them, and the Option 1 restore keeps working. Option 1 needs a "list a victim's clips by node ID" query (`getEvidenceHistory` today). The chaincode must provide the same, via a composite-key index on `victimNodeId` (section 4).

## 4. Identity, permissions and access control

### Organisation level: who is "authorised"

- Each org has its own **Fabric CA** and **MSP**. An org is trusted only because its MSP is in the channel configuration.
- **Onboarding the simulated authority** is itself a good demo step: create `SimPoliceMSP`, then submit a **channel config update** signed by the existing org admins as the channel's admin policy requires (MAJORITY by default). Follow the `fabric-samples/test-network/addOrg3` flow, renamed for SimPolice; don't invent a custom one.
- **Offboarding** is the reverse config update. Show that after removal, its officers' transactions are rejected.

### User level: officer roles (attribute-based access control)

Officers are enrolled by SimPolice's own CA with attributes embedded in their certificate:

```
fabric-ca-client register --id.name officer1 --id.type client \
  --id.attrs 'role=officer:ecert,unit=demo-unit:ecert,jc.simulated=true:ecert'
fabric-ca-client register --id.name supervisor1 --id.type client \
  --id.attrs 'role=supervisor:ecert,jc.simulated=true:ecert'
```

The `:ecert` suffix is required. Without it the attribute isn't placed in the enrolment certificate, and `getAttributeValue('role')` returns nothing. **Check this against the Fabric CA docs when building.**

Chaincode checks both the org and the role:

```js
const msp  = ctx.clientIdentity.getMSPID();             // 'SimPoliceMSP'
const role = ctx.clientIdentity.getAttributeValue('role'); // 'officer'
if (msp !== 'SimPoliceMSP' || role !== 'officer') throw new Error('Not authorised');
```

### Permission matrix

| Chaincode function | Who may call | Notes |
|---|---|---|
| `AnchorEvidence` | JusticeChainMSP gateway | A recoverable **device signature** is required; the chaincode records the recovered signer address. It doesn't yet know which address belongs to which node ID, so verifiers compare the signer with the victim's known anchoring address, as the app does today |
| `VerifyEvidence`, `GetEvidenceHistory` | Any channel member | Metadata only: hash, CID, time |
| `ShareWithAuthority` | JusticeChainMSP gateway | Requires a victim-signed **consent** record naming the authority |
| `RequestAccess` | SimPoliceMSP, `role=officer` | Records reason + demo case reference |
| `ReleaseShare` | JusticeChainMSP gateway, carrying a **victim** or **guardian** device signature | The approval **is** a key release (see below). Stores a second sealed piece for SimPolice |
| `GetAuthorityShare` | SimPoliceMSP `role=officer` | Reads SimPolice's own piece, plus any released piece, from the private collection |
| `RecordAccess` | Whoever decrypted | Mandatory audit entry: "opened", "exported" |
| `GetAuditTrail` | Victim (via gateway), SimPolice supervisor, Auditor | Chain of custody |

### Approval means releasing a key piece

A ledger record that says "approved" gives the police nothing to decrypt with. So approving a request is an **actual key release**, by one of these:

- **The victim approves.** The phone issues a **new** Shamir piece for that recording, seals it to SimPolice's X25519 key, signs the release with the device key, and submits it through the gateway. The app can already do this: `EvidenceEncryptor.issueGuardianShare` (`lib/core/evidence_encryptor.dart`) issues a piece for an existing recording that combines with the pieces issued at recording time. It needs the victim's own phone, or a phone restored with the Option 1 recovery code, because the recording key is wrapped under the device key.
- **A personal guardian releases their piece.** The guardian's app unseals their own piece, re-seals it to SimPolice's key with `EvidenceEncryptor.sealShare` (already used to forward a piece to a co-guardian), signs the release with the guardian's device key, and submits it through the gateway. Guardians have no Fabric identity, so the chaincode verifies the guardian's signature and checks they are a registered guardian of that victim. **This is the main path when the victim can't act.**

The chaincode rejects a release that doesn't carry a valid victim or guardian signature, so an officer can't "approve" their own request.

**Open item (decide before Step 8):** to check a consent or a release, the chaincode must know which signing address belongs to which node ID, and which guardians belong to which victim. Today it only records the recovered signer (Step 3, same as `JusticeLedger.sol`). Options: bind a node ID to the signer of its first anchor, or have each phone register itself with a self-signed registration. Choose one before building Step 8.

**Decided 12-10-2026: self-registration.** Each phone registers its node ID once, signed with its own key, and the victim's phone registers its guardian list the same way. The chaincode then checks consents and releases against these registrations. First-anchor binding was rejected because it can't record guardians, which guardian releases need. The future SOS hardware device can register through the same mechanism.
| `RegisterAuthority` / `RevokeAuthority` | Channel admins | Registry of authority orgs, with a `simulated: true` flag |

### Endorsement policies

- Chaincode-level: `MAJORITY Endorsement`, so no single org's peer can write records alone.
- **State-based (key-level) endorsement** on access-request and release keys: **JusticeChainMSP AND Org2MSP (Auditor)** must both endorse (`setStateValidationParameter`). SimPolice's peer can't endorse its own approval.
- **Private data writes (Step 8):** with 3 organisations, MAJORITY endorsement could pick the Auditor to endorse a write to `authorityShares_SimPolice`, but the Auditor isn't a collection member. Give that collection its own endorsement policy limited to its members. Check the Fabric private-data docs for the collection `endorsementPolicy` and `memberOnlyWrite` settings when building Step 8.

### Private data collections

| Collection | Members | Contents |
|---|---|---|
| `authorityShares_SimPolice` | JusticeChainMSP, SimPoliceMSP | The **sealed** Shamir share for each consented clip |
| `caseReferrals_SimPolice` | JusticeChainMSP, SimPoliceMSP | Victim contact / referral details for a case |

- Sealed shares are sent as **transient data** (`ctx.stub.getTransient()`), never as normal arguments. Normal arguments end up in the block.
- Only the **hash** of the private data is written to the channel ledger, so tampering is detectable.
- Set `blockToLive` to demonstrate retention limits, e.g. purge after N blocks once a case is closed.
- **Double protection:** each share is sealed to an **X25519 key held by the org's evidence desk**, separate from its Fabric signing certificate. Even a peer admin who can read the collection can't use the share without that key.

## 5. Workflow (demo script)

**Setup**
1. Start the network: JusticeChainOrg, Auditor and orderer (`test-network` based, Docker).
2. Onboard SimPoliceOrg via a channel config update (section 4).
3. Enrol `officer1` and `supervisor1` with role attributes.

**Victim side (demo build)**
4. Victim registers, adds one personal guardian, and turns on **"Add authority guardian: Demo Police Authority (SIMULATED)"**. A consent screen shows the "no real police are contacted" notice. The victim's device signs a consent record.
5. An incident is recorded. The clip is encrypted, uploaded to IPFS and anchored via the gateway (`AnchorEvidence`, device signature verified in chaincode).
6. Shamir shares, threshold 2:
   - personal guardian's share: over the mesh, as today;
   - SimPolice share: sealed to SimPolice's X25519 key, written to `authorityShares_SimPolice` via `ShareWithAuthority`.

**Authority side**
7. The SimPolice officer portal receives a chaincode event and shows **metadata only**: hash, time, "1 of 2 key pieces held". It can't open the clip.
8. Officer calls `RequestAccess(manifestHash, reason, "DEMO-CASE-001")`.
9. Approval is a key release (`ReleaseShare`, section 4) by **one** of these:
   - **a.** the victim approves in the app, which issues a new piece sealed to SimPolice (device-signed);
   - **b.** a personal guardian re-seals their own piece to SimPolice (guardian-signed). This is the path when the victim can't act.
10. The officer portal now has 2 shares. It reconstructs the key, downloads from IPFS, decrypts, verifies the hash against the ledger and the victim's device signature, and calls `RecordAccess`.
11. Show `GetAuditTrail`: anchor, consent, request, approval, access, each with org, identity and timestamp.

**Negative tests to show live** (each should fail)
- An officer without `role=officer` calls `RequestAccess`: rejected by chaincode.
- The Auditor (Org2) tries to read `authorityShares_SimPolice`: not a collection member.
- SimPolice with only its own share tries to decrypt: AES-GCM rejects the key.
- The officer tries to approve their own request: rejected twice over, because there's no valid victim or guardian signature and the JusticeChain + Auditor endorsement policy isn't met.
- After SimPolice is removed from the channel: its transactions are rejected.
- Edit one byte of the clip on IPFS: hash verification fails.

## 6. How this fits the open guardian problems

| Case | With this design |
|---|---|
| Victim can respond | Victim releases a piece to SimPolice: openable, through the audited flow |
| Victim has 1+ personal guardians, can't act | A guardian releases their piece to SimPolice: openable, through the audited flow |
| Victim has 0 personal guardians **and** can't act | **Not openable** by the police. Covered only by Option 1 (recovery code). In a real deployment an independent order, e.g. from a court, would hold the second piece; this is future work |
| Victim has 0 guardians and opted out of authority guardians | Still needs Option 1 (recovery code) |
| Time-based release (Option 4) | Fabric **can't** enforce it by releasing a key, because chaincode can't hold secrets. It can only record the timer; a share holder must still act. Keep it as future work. |

## 7. Practical notes

- **Windows 11:** the Fabric test-network needs **Docker Desktop with WSL2**; run the scripts inside WSL (Ubuntu).
- **State persistence:** `network.sh down` deletes the ledger, which is the same problem as the Hardhat node being wiped. For the Option 1 restore demo, keep the Docker volumes (stop containers, don't tear down).
- **Chaincode language:** JavaScript/TypeScript matches the team's existing Node tooling (Hardhat). Go is also fine.
- **Signature verification in chaincode:** use the same curve as the app's signing key (secp256k1 today), with a Node library such as `@noble/secp256k1` or `ethers`.
- **Suggested order:** (1) network + onboarding + `AnchorEvidence`/`VerifyEvidence` via the gateway; (2) `LedgerService` interface in the app; (3) private collections + sealed authority share; (4) request/approve/audit + officer portal; (5) negative tests.

## 8. Decisions for the team

1. **Approve the simulated authority** under the hard requirements in section 1, including the demo-build-only flag?
2. ~~Two simulated institutions or police only?~~ **Decided 08-10-2026:** police only. Org2 is kept as a neutral Auditor with no key piece. The zero-guardian, victim-can't-act case is left to Option 1 and presented as future work (court order).
3. **Fabric alongside or instead of Polygon Amoy (Phase 7)?** This design keeps both behind `LedgerService`.
4. **Confirm with the project guide** that a simulated authority, with the disclosure wording in section 1, is acceptable for the evaluation.

## 9. Implementation checklist

Steps 1–4 move the ledger to Fabric without any authority. Steps 5–10 are the authority feature. Step 11 was dropped on 08-10-2026.

- [x] **Step 0: Approvals.** Team and project guide agreed to use a simulated authority, with the name "Demo Police Authority (SIMULATED)" and the disclosure wording in section 1. *(done 08-10-2026)*
- [x] **Step 1: Set up the tools (Windows).** *(done 08-10-2026: Ubuntu on D:\WSL\Ubuntu, Docker Desktop data on D:, Node 20.20.2, Fabric 2.5.16, CA 1.5.17, in `~/fabric` inside WSL)* WSL2 + Ubuntu, Docker Desktop with WSL integration, Node 18+ and `jq` inside WSL. Download Fabric with `install-fabric.sh docker samples binary`.
  - Check: `docker ps` works inside WSL, and `fabric-samples/test-network` exists.
- [x] **Step 2: Start the base network.** *(done 08-10-2026: 3 CAs, orderer, peer0.org1, peer0.org2 up; both peers joined `evidence-channel` at height 3)* `./network.sh up createChannel -c evidence-channel -ca`. Org1 = JusticeChainOrg, Org2 = Auditor (SIMULATED) (label only; sample MSP names kept).
  - Check: channel created; 2 peers, 1 orderer and 3 CAs running.
  - Never run `network.sh down` before a demo; it deletes the ledger. Use `docker stop` / `docker start`.
- [x] **Step 3: First chaincode.** *(done 08-10-2026, version 1.0, sequence 1)* `fabric/chaincode/justiceledger` in this repo (JavaScript): `AnchorEvidence` (Org1MSP submitters only; recovers and records the secp256k1 device signer), `VerifyEvidence` (`found: false` for unknown hashes), `GetEvidenceHistory` (by node ID, in anchoring order). Unit tests: `npm test` (8 tests). The Dart test `test/anchor_signature_vector_test.dart` pins the same app-produced signature, so the app and the chaincode stay in agreement.
  - Deploy: copy the folder without `node_modules`/`test` to `~/fabric/cc/justiceledger` in WSL, then `./network.sh deployCC -ccn justiceledger -ccp ~/fabric/cc/justiceledger -ccl javascript -c evidence-channel`. Develop and run tests in `~/fabric/cc-dev/justiceledger`, never in the repo, so `node_modules` stays out of git.
  - Checks passed (invoked on both peers with `--waitForEvent`, then queried): an app-signed record commits and both peers return the device address as signer; a signature over a different hash records a different signer; a duplicate (even as `0x` + uppercase), a malformed signature, an empty CID and an Org2 submitter are all rejected with the right message, and nothing is written.
  - **Time caveat:** `anchoredAt` (and the order of `GetEvidenceHistory`) comes from the transaction timestamp, which in Fabric is set by the submitting client, i.e. the JusticeChain gateway, not by the ledger. Unlike `block.timestamp` on the EVM, it's only as trustworthy as the gateway. The independent evidence of ordering is the block the transaction committed in. Fabric blocks carry no timestamp, so in Step 4 the gateway must return the commit's block number, and `FabricLedgerService` must not label the gateway's time as "block time" (the app's verifier shows a block time today via `findAnchorBlock`).
  - Test data left on the ledger (permanent): node ID `0123456789abcdef` with 2 records (`53f7a635…` and `aaaa…`). Never reuse that node ID for real data.
- [ ] **Step 4: Gateway API and app switch.** Node service using `@hyperledger/fabric-gateway` with Org1's identity: `POST /anchor`, `GET /verify/:hash`, `GET /history/:nodeId`. Run it on the Windows side so the phone can reach it. In the app, add a `LedgerService` interface with `EvmLedgerService` (today's code) and `FabricLedgerService`, chosen in `.env` (`LEDGER=fabric`, `GATEWAY_URL`).
  - Check: an SOS recording on the phone is stored on Fabric, and Verify passes.
  - [x] **4a. Gateway service** *(done 09-10-2026)*: `fabric/gateway/server.js`, run on Windows with `npm start` in `fabric/gateway` (port 8800). It connects as Org1 `User1` using the certificates in WSL (`\\wsl.localhost\Ubuntu\...\test-network\organizations`); the peer's gateway collects Org2's endorsement automatically. Routes: `GET /health`, `POST /anchor`, `GET /verify/:hash` and `GET /history/:nodeId`. Anchor and verify return the commit's **block number**; `anchoredAt` stays labelled as the gateway's time. Chaincode refusals become HTTP 400 with the chaincode's message. Checks passed: anchor committed in block 8 with the right signer; duplicate, bad signature and non-JSON body each got a 400; verify and history correct; the phone reached `/health` over Wi-Fi. No firewall rule was needed: Windows already allows `node.exe` inbound. The laptop's Wi-Fi IP changes between networks (10.35.251.51 on 08-10, 10.159.143.50 on 09-10 on "Ayyy"), so the app must read it from `.env`.
  - [x] **4b. App switch** *(done 09-10-2026)*:
    - `AnchoringService` stays the app's only entry point, with the same methods (`signAnchor`, `recordAnchor`, `verifyEvidence`, `findAnchorBlock`), plus a new `getEvidenceHistory` for the Option 1 restore. It delegates to the ledger chosen in `.env`.
    - The ledger code lives in `lib/core/ledger/`: `ledger_service.dart` (interface), `evm_ledger_service.dart` (the old Hardhat code, moved unchanged) and `fabric_ledger_service.dart` (calls the gateway).
    - `.env`: `LEDGER=evm` (default) or `LEDGER=fabric` with `GATEWAY_URL=http://<laptop Wi-Fi IP>:8800`. `.env` is bundled into the app, so rebuild after changing it.
    - Fabric records carry `anchoredAtIsLedgerTime: false` and no block time. The guardian verifier (`GuardianEvidenceService.describeAnchor`) shows "anchored in block N · gateway time …" for them, and "anchored in block N at …" for EVM.
    - Checks passed: 98 tests (16 new unit tests for the Fabric ledger, the ledger selector, failures becoming null, and the anchor labels). Live round trips from Dart: `test/fabric_ledger_service_test.dart` against the gateway (`FABRIC_GATEWAY_URL=http://localhost:8800`), and `test/evm_ledger_service_test.dart` against a temporary local Hardhat node (`HARDHAT_RPC_URL`, `HARDHAT_CONTRACT_ADDRESS`). Each anchored a Dart-signed record, read back the right signer, block and history, and got "Evidence already stored" on a repeat.
    - Each live Fabric run adds one permanent test record under node `0123456789abcdef`.
  - [ ] **4c. Phone test**: SOS recording stored on Fabric, Verify passes on the phone.
- [x] **Step 5: Add the mock police organisation.** *(done 12-10-2026)* Copy `addOrg3` to `addSimPolice`: organisation ID `SimPoliceMSP`, domain `simpolice.example.com`, certificate `O=SimPolice (SIMULATED)`. Run the script to sign the configuration change and join the peer. Install the chaincode on the SimPolice peer, then approve the next chaincode definition from all 3 organisations and commit it.
  - Check: the SimPolice peer shows the same block height as the others (`peer channel getinfo`).
  - Scripts (in the repo, re-runnable on the cloud server, run inside WSL):
    - `fabric/network/add-simpolice.sh` makes the renamed copies `addSimPolice/` and `scripts/simpolice-scripts/` in fabric-samples, and points the shared `envVar.sh` and `setAnchorPeer.sh` at SimPolice for "org 3" (originals kept as `.orig`). It then runs the sample's own flow: CA and identities, a channel config update signed by the Org1 and Org2 admins, joining the peer, and setting the anchor peer. It stops if SimPoliceMSP is already in the channel.
    - `fabric/network/upgrade-chaincode.sh [version]` installs the chaincode on every peer, approves the next definition from all 3 orgs and commits it. With no version it re-commits the installed package; with a version it packages `fabric/chaincode/justiceledger` from the repo. `COLLECTIONS=...` adds a collections config (Step 8).
  - Checks passed: all three peers at height 12 after joining. SimPolice certificates read `C=IN, ST=Karnataka, L=Bengaluru, O=SimPolice (SIMULATED)` (CA, peer and user1). `justiceledger` 1.0 committed as sequence 2 with approvals from Org1MSP, Org2MSP and SimPoliceMSP. The SimPolice peer returns the existing records. The live Dart anchor test passed through the gateway with endorsement now MAJORITY of 3 (any 2 orgs).
  - SimPolice runs `ca_simpolice` (port 11054) and `peer0.simpolice.example.com` (port 11051). After a laptop restart, `docker start` them too.
- [x] **Step 6: Officer identities and roles.** *(done 12-10-2026)* Register `officer1` (`role=officer:ecert,jc.simulated=true:ecert`) and `supervisor1` (`role=supervisor:ecert,jc.simulated=true:ecert`) with SimPolice's CA. Add a `WhoAmI` chaincode function.
  - Check: `WhoAmI` as officer1 returns `SimPoliceMSP / officer`. An empty role means the `:ecert` suffix is missing.
  - `fabric/network/enroll-simpolice-officers.sh` registers and enrolls both (officer1 also gets `unit=demo-unit:ecert`), into `organizations/peerOrganizations/simpolice.example.com/users/<name>@simpolice.example.com/msp`. Demo passwords: `officer1pw`, `supervisor1pw`. Safe to re-run.
  - `WhoAmI` returns `{mspId, id, role, unit, simulated}`; an attribute missing from the certificate is `null`. Deployed as `justiceledger` 1.1, sequence 3, with `upgrade-chaincode.sh 1.1`. Chaincode unit tests: 10 (2 new).
  - Checks passed: officer1 → `SimPoliceMSP`, `officer`, `demo-unit`, `simulated: true`. supervisor1 → `SimPoliceMSP`, `supervisor`, `simulated: true`. Org1 User1 → `Org1MSP`, role `null`, `simulated: false`. Both officers' certificates read `O=SimPolice (SIMULATED)`, and existing records are still readable after the upgrade.
- [x] **Step 7: Authority encryption key.** *(done 12-10-2026)* Generate an X25519 key pair for the SimPolice evidence desk, separate from its Fabric certificates. `RegisterAuthority` (channel admins only) stores `{mspId, name, publicKey, simulated: true}`.
  - Check: the app can fetch SimPolice's public key through the gateway.
  - "Channel admins" was built as: an admin (`hf.Type=admin` in the certificate) of **Org1MSP or Org2MSP**. A single transaction can't prove a channel-wide MAJORITY of admins. Instead, each authority entry gets a **key-level endorsement policy of Org1 AND Org2 peers**, so after registration neither JusticeChainOrg nor the Auditor can change or revoke an entry alone. Org1 and Org2 themselves can't be registered as authorities.
  - Chaincode 1.2 (sequence 4):
    - `RegisterAuthority(mspId, name, publicKey, simulated)`: `publicKey` is a raw 32-byte X25519 key in base64, as the app stores keys. A simulated authority's name must contain "(SIMULATED)". An active authority can't be registered twice; a revoked one can be registered again.
    - `RevokeAuthority(mspId)`: the entry is kept for the audit trail and marked `revoked`, with `revokedAt` and `revokedBy`.
    - `GetAuthority(mspId)` (`found: false` if unknown) and `ListAuthorities()`, readable by any member.
    - Chaincode unit tests: 16 (6 new).
  - Gateway: `GET /authorities` and `GET /authorities/:mspId` (read-only; the gateway's User1 identity isn't an admin).
  - `fabric/network/register-authority.sh` creates the desk key once, then registers "Demo Police Authority (SIMULATED)" as the Org1 admin, endorsed by the Org1 and Org2 peers. The private key never leaves WSL: `organizations/peerOrganizations/simpolice.example.com/evidence-desk/x25519_private.pem` (folder 700, file 600), next to `x25519_public.b64`. The officer portal (Step 10) will read it from there. Safe to re-run.
  - Checks passed:
    - Registered key `HppaIRVX6LdY5srCCRVbqsNGe9kGh07+P8MVpRCtohs=`.
    - officer1 calling `RegisterAuthority` is refused ("Only an admin of Org1MSP or Org2MSP…").
    - An Org1-admin revoke endorsed by Org1 + SimPolice (no Auditor) is invalidated with `ENDORSEMENT_POLICY_FAILURE`, and the entry stays active.
    - Over the laptop's Wi-Fi address, `/authorities` and `/authorities/SimPoliceMSP` return the entry with the same key as the desk file. An unknown ID gives `found: false`, and a malformed ID gives HTTP 400.
    - The live Dart anchor test still passes on 1.2.
  - The app-side client for these routes comes with Step 8, where the app first uses the key.
- [ ] **Step 8: Private collection and sharing the key piece.** `collections_config.json` with `authorityShares_SimPolice` (Org1 + SimPolice), with a collection endorsement policy limited to its members so the Auditor is never picked to endorse it. Upgrade with `--cc-coll-config` and approve the next sequence from all organisations. `ShareWithAuthority` reads the encrypted piece from transient data and checks the victim-signed consent. In the app, behind a `DEMO_AUTHORITY` build flag: the authority as a guardian option with the "No real police are contacted. In an emergency call 112." notice, a signed consent record, one extra Shamir piece (still 2 needed) encrypted to the authority's key.
  - Check: the officer can read the collection entry; an Org2 (Auditor) identity gets "not a member"; the block holds only the hash.
- [ ] **Step 9: Request, release and audit.** `RequestAccess` (officer role only); `ReleaseShare`, where approval is an actual key release: the victim's phone issues a new piece (`issueGuardianShare`), or a guardian re-seals their own piece (`sealShare`), sealed to SimPolice's key and device-signed. Key-level endorsement needs Org1 + Org2 (Auditor). Also `GetAuthorityShare`, `RecordAccess` and `GetAuditTrail`. In the app: an "Access requests" screen for the victim and a "Release my piece" action for guardians, plus a gateway endpoint and a chaincode check of the guardian's signature and guardian registration.
  - Check: a release without a valid victim or guardian signature is rejected; an officer can't approve their own request; every step appears in the audit trail.
- [ ] **Step 10: Officer portal (simulated).** Web page with a permanent SIMULATED banner and a Node backend using officer1's identity: list shared evidence, request access, fetch and decrypt the key piece, collect the second piece, rebuild the key, download from IPFS, decrypt, check hash and signature, call `RecordAccess`. The JavaScript Shamir code must match `lib/core/shamir.dart` exactly; test it against pieces exported from the Dart tests.
  - Check: a clip recorded on the phone plays in the portal after approval.
- ~~**Step 11: Second institution.**~~ **Dropped 08-10-2026** (decision 2 in section 8). Presented as future work: a court order as the second piece.
- [ ] **Step 12: Failure tests and demo script.** Wrong role, Auditor reading the police collection, police with one piece, self-approval, release without a valid signature, SimPolice removed, tampered IPFS file. Write the demo script and test log in `DOCS/`, and add the disclosure slide.
