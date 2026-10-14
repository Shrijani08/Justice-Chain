# Guardian Quorum and Evidence Recovery: Decision Needed (08-10-2026)

**Status:** option 2 is built and committed (`963e441d`). **Option 1 was approved and built on 14-10-2026**: base32 code, on the Fabric ledger, details in `DOCS/14-10-2026 remaining steps.md` step 6. Device test pending (step 9).

## 1. The problem

Every recording is encrypted with its own key. Today a recording can be opened in two ways:

| Situation | Can the recording be opened? |
|---|---|
| The victim, on their own phone | ✅ Always, even with zero guardians. Each clip's key is also locked to the phone's own device key ("My Evidence"). |
| Phone lost/destroyed **or** victim unable to act, **2+ guardians** | ✅ Any 2 guardians combine their key pieces (Shamir 2-of-N) |
| Phone lost/destroyed **or** victim unable to act, **only 1 guardian** | ❌ **Nobody can open it** |
| Phone lost/destroyed **or** victim unable to act, **no guardians** | ❌ **Nobody can open it** |

In the ❌ cases the evidence isn't destroyed. The encrypted file is still on IPFS, and the blockchain record still proves it existed and hasn't been changed. But nobody can watch it, which defeats the purpose in exactly the worst situation.

**Why 2 guardians:** if one guardian could open clips alone, a single person could watch them, and that person might be the abuser or someone pressured by them. Requiring 2 means one bad guardian isn't enough.

## 2. Options considered

| # | Option | Summary | Status |
|---|---|---|---|
| 1 | **Victim recovery code** | A code shown at registration lets the victim restore their identity on a new phone and open their own clips with **zero guardians**. | **Decision needed** (section 4) |
| 2 | **One guardian can be enough (opt-in)** | A victim with only one trusted person can choose to let that guardian open clips alone. | **Built** (section 3) |
| 3 | Organisation as a guardian | A police unit, NGO or legal-aid service holds one key piece. | Future work (Phase 8, needs a real partner) |
| 4 | Time-based release | After e.g. 72 h without a response from the victim, one guardian is enough. | Future work (needs a server or smart contract to enforce the timer) |

Options 1 + 2 together cover every case:
- The victim can always open their own evidence, even from a new phone.
- Someone with only one trusted person can still choose to let them open clips.
- Everyone else keeps the 2-guardian protection.

## 3. Option 2: built (pending device test and review)

- **The switch:** "Let one guardian open my recordings", on the **My Guardians** screen. Off by default.
- **Turning it on:** a confirmation explains:
  - While you have fewer than 2 guardians, any one guardian can open your new recordings alone.
  - Recordings made in this mode **stay single-guardian for good**, even after more guardians are added or the switch is turned off. A guardian added later can also open them alone.
  - Only turn it on if you fully trust your guardian.
- **Each recording keeps its own rule.** A clip is single-guardian only if the switch was on **and** fewer than 2 guardians could hold key pieces when it was recorded. With 2+ guardians, new clips need 2 again.
- **Older clips are unaffected:** existing recordings still need 2 guardians.
- **Guardian side:** the Guardian Evidence screen shows the right count (e.g. "key pieces 1/1"), and **Open & verify** works with one piece for those clips.
- **Safety:** the "1 or 2" number a phone sends is only used for display. The maths fixed when the clip was encrypted (the degree of the Shamir polynomial) decides who can open it. A phone that sends the wrong number can't open a 2-guardian clip with one piece; AES-GCM rejects the wrong key. There is a test for this.
- **Tests:** 81 of 81 unit/widget tests pass, including new tests for threshold-1 encryption, late-issued pieces, and the switch and banner UI.

## 4. Option 1: recovery code, terms for the team to agree

**What it would do:** to let a victim open their clips on a **new phone** using only the code, the code has to rebuild the phone's identity: its node ID, its signing key and the key for each clip.

**What the team must accept:**

1. **Existing installs must re-register.** That includes both current test phones, and guardians must be paired again. Current identities were created randomly and can't be turned into a code after the fact.
2. **Only clips recorded after the change can be recovered.** Earlier clips used random keys.
3. **The blockchain must still have the records.** A new phone finds its clips by reading the blockchain. The local Hardhat chain is wiped whenever the node stops, so a restore demo needs the node left running, or Phase 7 (Polygon Amoy), where records are permanent.
4. **Anyone who gets the code** can act as the victim's phone and open their new clips. It must be kept safe, like a crypto wallet's seed phrase. If an abuser finds it, the protection is gone.
5. **The restored phone starts with no guardian list.** The victim re-scans their guardians; the guardians still recognise the victim.

**Proposed design:**
- **The code:** a short code shown **once** at registration, e.g. `K7Q2M-9XMPA-…` (128 random bits in base32 groups), with a built-in checksum so a typo is caught. The user retypes part of it to confirm they saved it.
- **Keys:** all identity keys (Ed25519, X25519, secp256k1 signing key) and an "evidence root" are derived from the code with HKDF, using a separate label for each. Each clip's key is derived from the evidence root and the clip's content hash, which is already recorded on the blockchain. So nothing extra has to be stored off the phone.
- **Restore:** a **"Restore with recovery code"** option on the registration screen. It rebuilds the identity, lists the victim's clips from the blockchain (`getEvidenceHistory`), and plays them in My Evidence by downloading from IPFS and decrypting.
- **Already checked:** clips a guardian relays and anchors for the victim are recorded under the **victim's** node ID, so a restore would find them too.

## 5. Decisions for the team

1. **Approve option 1** on the terms in section 4? (yes / no / changes)
2. **When:** before or after Phase 7 (Polygon Amoy)? Without Amoy, a restore only works while the local node keeps running.
3. **Code format:** a short base32 code as proposed, or a 12-word phrase (easier to write down, but needs a word list)?
4. **Option 2:** keep it as built (opt-in, off by default)?
5. **Options 3 and 4:** present as future work in the final presentation?

**Suggested order:** test the Guardians screen and option 2 on the phones and commit them first. Then build option 1 if approved, since it touches some of the same files.
