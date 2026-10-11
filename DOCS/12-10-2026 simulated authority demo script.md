# Simulated authority: demo script (12-10-2026)

How to show the Demo Police Authority (SIMULATED) at the review: what to start, what to click, and what to say. It goes with `DOCS/08-10-2026 simulated authority guardian on Fabric design.md` and `DOCS/12-10-2026 simulated authority failure test log.md`.

**Status:** everything on the ledger, gateway and portal works and is tested. Two parts of the flow below need app screens that come with the phone session; they are marked *(app screen, step 8d / 9c)*. Until then, the same flow can be shown with the dry-run test (`test/portal_live_test.dart`), which uses the app's real recording code.

## 1. Disclosure slide (show first)

Put this on its own slide before the demo, and say it out loud:

> **Demo Police Authority (SIMULATED)**
>
> - The "police" in this demo is fictional. It is a simulated organisation on our test blockchain, created to show how an authority **could** take part.
> - No real police force, court or emergency service is connected, contacted or represented.
> - Every SimPolice certificate is labelled "SimPolice (SIMULATED)", and the officer portal shows a permanent SIMULATED banner.
> - "Auditor" is also a demo label for a neutral organisation; it is the test network's Org2.
> - All evidence in the demo is test footage recorded for the demo.
> - **In a real emergency, call 112.**

## 2. Before the review (about 10 minutes)

1. Open **Docker Desktop** and wait until it says it's running.
2. Start the Fabric network (in Git Bash):
   ```
   wsl -d Ubuntu bash -l /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/start-network.sh
   ```
   It must list 8 containers as `up` and three equal peer heights.
3. Check the laptop's Wi-Fi address (`ipconfig`). If it isn't the one in `.env` (`GATEWAY_URL`), update `.env` and rebuild the app. After the cloud move, this step goes away.
4. Start the **gateway** in its own PowerShell window and leave it open:
   ```
   cd D:\Justice-Chain\justice-chain2\Justice-Chain\fabric\gateway
   npm start
   ```
5. Start the **officer portal** in a second window and leave it open:
   ```
   cd D:\Justice-Chain\justice-chain2\Justice-Chain\fabric\portal
   npm start
   ```
   Open `http://localhost:8900` in a browser. The header must read "SimPoliceMSP · officer · demo-unit · SIMULATED".
6. Phones: the victim phone and one guardian phone on the same Wi-Fi as the laptop, both paired as victim and guardian, both with the authority option turned on *(app screen, step 8d)*.
7. Rehearse once with a throwaway recording, so the clip is pinned on IPFS and everything is warm.

## 3. The demo (about 8 minutes)

| # | Do | Show | Say |
|---|---|---|---|
| 1 | Victim phone: press SOS and record a short clip | The app encrypts, uploads and anchors it | "The clip is encrypted on the phone before it leaves. Only a hash and the encrypted file's address go on the ledger." |
| 2 | Victim phone: the clip is shared with the Demo Police Authority *(app screen, step 8d)* | Portal: refresh; the clip appears, "No request yet", "Holds piece 2 · 2 pieces needed" | "The police got one key piece, locked to their evidence desk key. One piece can't open anything; the key needs two." |
| 3 | Portal: click **Open and verify** | It stops at "1 of 2 pieces held" | "The police can't open it on their own." |
| 4 | Portal: enter a reason and case reference, click **Request access** | The request appears with status "open" | "The request is on the ledger with who asked and why." |
| 5 | Guardian phone: approve by releasing their piece *(app screen, step 9c)* | Portal: refresh; status "released by the guardian" | "Only the victim or one of her guardians can approve, by releasing their own piece. JusticeChain **and** the independent Auditor both have to endorse the approval, and the Auditor never sees the piece itself." |
| 6 | Portal: click **Open and verify** | Each check turns green, then the video plays | "The portal unlocks both pieces, rebuilds the key, downloads the encrypted clip from IPFS and decrypts it. Then it checks the clip's hash against the ledger and checks that the victim's registered phone signed the record." |
| 7 | Portal: click **Audit trail (supervisor)** | shared → requested → released → opened | "Every step is recorded permanently. The supervisor and the Auditor can read it; the officers it records can't." |

## 4. If asked "what stops misuse?"

Show one or two lines from the failure test log, or re-run the ledger checks live (about 2 minutes):
```
wsl -d Ubuntu bash -l /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/failure-tests.sh
```
Good ones to point at:
- **4b:** a release without the Auditor is rejected by Fabric itself.
- **2b:** the Auditor's peer has no copy of police pieces.
- **7a:** a single changed byte in the IPFS file is caught.

## 5. If something goes wrong

| Problem | Fix |
|---|---|
| Portal or gateway says "Fabric network unavailable" | Docker Desktop isn't running, or the network didn't start: run step 2 again |
| Phone can't reach the gateway | The laptop's Wi-Fi address changed: check step 3; Windows must allow `node.exe` on private networks |
| "Open and verify" stops at "Encrypted clip downloaded from IPFS" | No internet, or Pinata is slow: wait and retry; the rehearsal pins the file in advance |
| Port 8800 or 8900 already in use | An old gateway or portal window is still open: close it, or `taskkill /IM node.exe` (this also stops any other Node programs) |
