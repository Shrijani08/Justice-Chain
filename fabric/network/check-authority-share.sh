#!/usr/bin/env bash
# Step 8 check, officer side, after test/fabric_authority_live_test.dart has
# shared a piece (it writes build/authority_live_share.json):
#   1. officer1 reads the piece from SimPolice's peer and unseals it with the
#      evidence desk key: it must be exactly the piece the app sealed.
#   2. The Auditor's (Org2) peer has no copy of the private data.
#   3. The block that recorded the share holds only a hash of the piece.
#
#   bash /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/check-authority-share.sh
set -eo pipefail

RESULT=${1:-$(cd "$(dirname "$0")/../.." && pwd)/build/authority_live_share.json}
CHANNEL=${CHANNEL:-evidence-channel}
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
SIMPOLICE=$TN/organizations/peerOrganizations/simpolice.example.com
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config
. "$HOME/.nvm/nvm.sh" >/dev/null

HASH=$(jq -r .manifestHash "$RESULT")
SEALED=$(jq -r .sealedShare "$RESULT")
BLOCK=$(jq -r .blockNumber "$RESULT")
cd "$TN"
. scripts/envVar.sh >/dev/null
quiet() { "$@" >/dev/null 2>&1; }
query() { peer chaincode query -C "$CHANNEL" -n justiceledger -c "{\"Args\":[\"GetAuthorityShare\",\"$HASH\"]}"; }
fail=0

echo "== 1. officer1 reads and unseals the piece on SimPolice's peer"
quiet setGlobals 3
export CORE_PEER_MSPCONFIGPATH=$SIMPOLICE/users/officer1@simpolice.example.com/msp
piece=$(query)
if [ "$(jq -r .sealedShare <<<"$piece")" = "$SEALED" ]; then echo "read: same sealed piece the app sent"; else echo "read: FAILED"; fail=1; fi
# The app's sealing (EvidenceEncryptor.sealShare): X25519, HKDF-SHA256 with
# no salt and info "justice-chain-guardian-wrap-v1", then AES-256-GCM stored
# as nonce(12) + mac(16) + ciphertext of [x] ++ piece.
unsealed=$(PIECE="$piece" DESK_KEY="$SIMPOLICE/evidence-desk/x25519_private.pem" node -e '
  const crypto = require("crypto"); const fs = require("fs");
  const piece = JSON.parse(process.env.PIECE);
  const sender = crypto.createPublicKey({ format: "der", type: "spki",
    key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(piece.senderX25519PublicKey, "base64")]) });
  const shared = crypto.diffieHellman({ privateKey: crypto.createPrivateKey(fs.readFileSync(process.env.DESK_KEY)), publicKey: sender });
  const key = Buffer.from(crypto.hkdfSync("sha256", shared, Buffer.alloc(0), "justice-chain-guardian-wrap-v1", 32));
  const box = Buffer.from(piece.sealedShare, "base64");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, box.subarray(0, 12));
  decipher.setAuthTag(box.subarray(12, 28));
  const plain = Buffer.concat([decipher.update(box.subarray(28)), decipher.final()]);
  console.log(JSON.stringify({ x: plain[0], yHex: plain.subarray(1).toString("hex") }));')
if [ "$(jq -c '{x, yHex}' "$RESULT")" = "$(jq -c '{x, yHex}' <<<"$unsealed")" ]; then
  echo "unseal: the desk key opens it to piece x=$(jq .x <<<"$unsealed"), identical to what the app sealed"
else
  echo "unseal: FAILED ($unsealed)"; fail=1
fi

echo "== 2. the same officer asks the Auditor's peer"
quiet setGlobals 2; ORG2_ADDR=$CORE_PEER_ADDRESS; ORG2_TLS=$CORE_PEER_TLS_ROOTCERT_FILE
quiet setGlobals 3
export CORE_PEER_MSPCONFIGPATH=$SIMPOLICE/users/officer1@simpolice.example.com/msp
export CORE_PEER_ADDRESS=$ORG2_ADDR CORE_PEER_TLS_ROOTCERT_FILE=$ORG2_TLS
if out=$(query 2>&1); then echo "auditor peer: returned data, FAILED: $out"; fail=1; else echo "auditor peer refused: $(grep -o 'Error.*' <<<"$out" | head -c 220)"; fi

echo "== 3. block $BLOCK holds only a hash of the piece"
quiet setGlobals 1
peer channel fetch "$BLOCK" /tmp/jc_block.pb -c "$CHANNEL" -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA" >/dev/null 2>&1
configtxlator proto_decode --input /tmp/jc_block.pb --type common.Block > /tmp/jc_block.json
if grep -q -- "$SEALED" /tmp/jc_block.json; then echo "block: contains the sealed piece, FAILED"; fail=1; else echo "block: sealed piece not present"; fi
collections=$(jq -r '[.. | objects | select(has("collection_name")) | .collection_name] | unique | join(",")' /tmp/jc_block.json)
echo "block: hashed private writes for collection(s): ${collections:-none}"
[ "$collections" = authorityShares_SimPolice ] || fail=1

[ $fail = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
