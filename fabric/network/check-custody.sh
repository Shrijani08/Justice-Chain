#!/usr/bin/env bash
# Step 9 live check, officer and network side, around
# test/fabric_custody_live_test.dart (state in build/custody_live_state.json):
#
#   check-custody.sh request   officer1 files two access requests for the
#                              clip shared in the "share" phase
#   check-custody.sh verify    after the "release" phase:
#     1. officer1 reads pieces 3 (shared) and 1 (released by the guardian),
#        unseals both with the desk key and recombines the clip's key
#     2. the delivery block holds only a hash of the released piece
#     3. officer1 records "opened"; the audit trail shows every step to the
#        Auditor and the supervisor, and is refused to the officer
#     4. officer1 can't approve request 2 themselves
#     5. a valid release of request 2 without the Auditor's endorsement is
#        invalidated, and request 2 stays open
set -eo pipefail

MODE=$1
STATE=${STATE:-$(cd "$(dirname "$0")/../.." && pwd)/build/custody_live_state.json}
LIB=$(cd "$(dirname "$0")" && pwd)/lib/evidence-crypto.cjs
CHANNEL=${CHANNEL:-evidence-channel}
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
SIMPOLICE=$TN/organizations/peerOrganizations/simpolice.example.com
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config
. "$HOME/.nvm/nvm.sh" >/dev/null

HASH=$(jq -r .manifestHash "$STATE")
cd "$TN"
. scripts/envVar.sh >/dev/null
quiet() { "$@" >/dev/null 2>&1; }
ORDERER=(-o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA")
quiet setGlobals 1; ORG1_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
quiet setGlobals 2; ORG2_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
quiet setGlobals 3; POLICE_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")

as_user() {  # as_user <org> <msp dir>: act as that identity on that org's peer
  quiet setGlobals "$1"
  export CORE_PEER_MSPCONFIGPATH=$2
}
as_officer() { as_user 3 "$SIMPOLICE/users/officer1@simpolice.example.com/msp"; }
as_supervisor() { as_user 3 "$SIMPOLICE/users/supervisor1@simpolice.example.com/msp"; }
query() { peer chaincode query -C "$CHANNEL" -n justiceledger -c "$(jq -cn --args '{Args: $ARGS.positional}' "$@")"; }
invoke() {  # invoke <peer args...> -- <function> <args...>
  local peers=()
  while [ "$1" != -- ]; do peers+=("$1"); shift; done; shift
  peer chaincode invoke "${ORDERER[@]}" -C "$CHANNEL" -n justiceledger "${peers[@]}" --waitForEvent \
    -c "$(jq -cn --args '{Args: $ARGS.positional}' "$@")" 2>&1
}
fail=0
ok() { echo "  PASS: $*"; }
bad() { echo "  FAIL: $*"; fail=1; }

if [ "$MODE" = request ]; then
  as_officer
  ids=()
  for ref in DEMO-REQ-1 DEMO-REQ-2; do
    out=$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- RequestAccess "$HASH" "Assault report (demo)" "$ref")
    id=$(grep -o 'txid \[[0-9a-f]*\] committed with status (VALID)' <<<"$out" | head -1 | grep -o '[0-9a-f]\{64\}')
    [ -n "$id" ] || { echo "$out" >&2; exit 1; }
    ids+=("$id"); echo "officer1 requested access ($ref): request $id"
  done
  jq '.requestIds = $ARGS.positional' "$STATE" --args "${ids[@]}" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  exit 0
fi

[ "$MODE" = verify ] || { echo "usage: check-custody.sh request|verify" >&2; exit 2; }

echo "== 1. officer1 recombines the clip key from piece 3 (shared) and piece 1 (released)"
as_officer
pieces=$(query GetAuthorityShare "$HASH")
key=$(PIECES="$pieces" LIB="$LIB" DESK="$SIMPOLICE/evidence-desk/x25519_private.pem" node -e '
  const crypto = require("crypto"); const fs = require("fs");
  const { unsealShare, combineShares } = require(process.env.LIB);
  const desk = crypto.createPrivateKey(fs.readFileSync(process.env.DESK));
  const p = JSON.parse(process.env.PIECES);
  const all = [p, ...p.released].map((s) => unsealShare(s.sealedShare, desk, s.senderX25519PublicKey));
  console.error("  pieces: " + all.map((s) => s.x).join(", "));
  console.log(combineShares(all).toString("hex"));')
[ "$key" = "$(jq -r .incidentKeyHex "$STATE")" ] && ok "recombined key equals the clip's key" || bad "recombined key differs"

echo "== 2. the delivery block holds only a hash of the released piece"
quiet setGlobals 1
peer channel fetch "$(jq -r .deliveryBlock "$STATE")" /tmp/jc_block.pb -c "$CHANNEL" "${ORDERER[@]}" >/dev/null 2>&1
configtxlator proto_decode --input /tmp/jc_block.pb --type common.Block > /tmp/jc_block.json
grep -q -- "$(jq -r .releasedSealedPiece "$STATE")" /tmp/jc_block.json && bad "block contains the piece" || ok "piece not in the block"
grep -q '"collection_name": *"authorityShares_SimPolice"' /tmp/jc_block.json && ok "block has hashed writes for authorityShares_SimPolice" || bad "no hashed private writes"

echo "== 3. audit trail"
as_officer
out=$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- RecordAccess "$HASH" opened "Viewed in the officer portal (check)") || true
grep -q 'status (VALID)' <<<"$out" && ok "officer1 recorded 'opened'" || bad "RecordAccess: $out"
quiet setGlobals 2
# Re-running this check appends another "opened": the trail only ever grows.
trail=$(query GetAuditTrail "$HASH")
events=$(jq -r '[.[].event] | join(",")' <<<"$trail")
[[ "$events" =~ ^shared,requested,requested,released(,opened)+$ ]] && ok "Auditor sees: $events" || bad "Auditor sees: $events"
as_supervisor
[ "$(query GetAuditTrail "$HASH")" = "$trail" ] && ok "supervisor1 reads the same trail" || bad "supervisor1 can't read the trail"
as_officer
query GetAuditTrail "$HASH" >/dev/null 2>&1 && bad "officer1 read the trail" || ok "officer1 is refused the trail"

echo "== 4. officer1 tries to approve request 2 themselves"
R=$(jq -c .unsubmittedRelease "$STATE")
args=("$(jq -r .requestId <<<"$R")" "$(jq -r .releaserNodeId <<<"$R")" "$(jq -r .shareX <<<"$R")" "$(jq -r .shareHash <<<"$R")" "$(jq -r .signature <<<"$R")")
as_officer
out=$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- ReleaseShare "${args[@]}") || true
grep -q 'Only Org1MSP may release' <<<"$out" && ok "refused: Only Org1MSP may release key pieces" || bad "$out"

echo "== 5. a valid release of request 2 without the Auditor's endorsement"
quiet setGlobals 1
out=$(invoke "${ORG1_PEER[@]}" "${POLICE_PEER[@]}" -- ReleaseShare "${args[@]}") || true
grep -q 'ENDORSEMENT_POLICY_FAILURE' <<<"$out" && ok "invalidated: ENDORSEMENT_POLICY_FAILURE" || bad "$out"
[ "$(query GetAccessRequest "${args[0]}" | jq -r .status)" = open ] && ok "request 2 is still open" || bad "request 2 changed"

[ $fail = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
