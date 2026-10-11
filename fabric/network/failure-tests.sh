#!/usr/bin/env bash
# Step 12: failure tests on the live network, ledger side. Each case must be
# refused; the script prints PASS when it is. The portal-side cases (a
# tampered IPFS file, opening with one piece) are in fabric/portal/failure-tests.sh.
#
# Needs the state left by the Step 8/9 live runs:
#   build/authority_live_share.json  a clip shared with SimPolice, never requested
#   build/custody_live_state.json    a released request and an open request 2,
#                                    with a valid signed release for request 2
# Run inside WSL:
#   bash /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/failure-tests.sh
#
# Case 9 revokes SimPolice and then registers it again with the same desk
# key (register-authority.sh), so the network ends as it started.
set -eo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CUSTODY=$REPO/build/custody_live_state.json
SHARED=$REPO/build/authority_live_share.json
CHANNEL=${CHANNEL:-evidence-channel}
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
ORGS=$TN/organizations/peerOrganizations
SIMPOLICE=$ORGS/simpolice.example.com
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config

cd "$TN"
. scripts/envVar.sh >/dev/null
quiet() { "$@" >/dev/null 2>&1; }
ORDERER=(-o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA")
quiet setGlobals 1; ORG1_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
quiet setGlobals 2; ORG2_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
ORG2_ADDR=$CORE_PEER_ADDRESS; ORG2_TLS=$CORE_PEER_TLS_ROOTCERT_FILE
quiet setGlobals 3; POLICE_PEER=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")

as() {  # as <org> <user dir under users/>, on that org's peer
  quiet setGlobals "$1"
  case $1 in 1) d=org1.example.com ;; 2) d=org2.example.com ;; 3) d=simpolice.example.com ;; esac
  export CORE_PEER_MSPCONFIGPATH=$ORGS/$d/users/$2/msp
}
args_json() { jq -cn --args '{Args: $ARGS.positional}' "$@"; }
query() { peer chaincode query -C "$CHANNEL" -n justiceledger -c "$(args_json "$@")" 2>&1; }
invoke() {  # invoke <peer args...> -- <function> <args...>
  local peers=()
  while [ "$1" != -- ]; do peers+=("$1"); shift; done; shift
  peer chaincode invoke "${ORDERER[@]}" -C "$CHANNEL" -n justiceledger "${peers[@]}" --waitForEvent \
    -c "$(args_json "$@")" 2>&1 || true
}

passed=0; failed=0
expect() {  # expect <case> <what was tried> <output> <pattern that proves the refusal>
  if grep -q -E -- "$4" <<<"$3"; then
    passed=$((passed + 1)); printf '  PASS  %-4s %s\n        -> %s\n' "$1" "$2" "$(grep -o -E -- "$4" <<<"$3" | head -1)"
  else
    failed=$((failed + 1)); printf '  FAIL  %-4s %s\n        got: %s\n' "$1" "$2" "$(tail -c 300 <<<"$3")"
  fi
}

for f in "$CUSTODY" "$SHARED"; do
  [ -f "$f" ] || { echo "Missing $f: run the Step 8 and Step 9 live tests first." >&2; exit 1; }
done
RELEASED_HASH=$(jq -r .manifestHash "$CUSTODY")
UNREQUESTED_HASH=$(jq -r .manifestHash "$SHARED")
R=$(jq -c .unsubmittedRelease "$CUSTODY")
REQ2=$(jq -r .requestId <<<"$R"); NODE=$(jq -r .releaserNodeId <<<"$R")
X=$(jq -r .shareX <<<"$R"); PIECE_HASH=$(jq -r .shareHash <<<"$R"); SIG=$(jq -r .signature <<<"$R")

echo "== Wrong role"
as 3 supervisor1@simpolice.example.com
expect 1a "supervisor1 requests access (only officers may)" \
  "$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- RequestAccess "$RELEASED_HASH" reason REF)" "officer may do this"
as 3 officer1@simpolice.example.com
expect 1b "officer1 reads the audit trail (not for the officers it records)" \
  "$(query GetAuditTrail "$RELEASED_HASH")" "supervisor may do this"
as 1 User1@org1.example.com
expect 1c "JusticeChain's ordinary user registers an authority (admins only)" \
  "$(invoke "${ORG1_PEER[@]}" "${ORG2_PEER[@]}" -- RegisterAuthority FakeMSP "Fake (SIMULATED)" "$(head -c 32 /dev/urandom | base64)" true)" \
  "Only an admin of Org1MSP or Org2MSP"

echo "== Auditor reading the police collection"
as 2 Admin@org2.example.com
expect 2a "the Auditor's admin asks for SimPolice's key piece" \
  "$(query GetAuthorityShare "$RELEASED_HASH")" "officer may do this"
as 3 officer1@simpolice.example.com
export CORE_PEER_ADDRESS=$ORG2_ADDR CORE_PEER_TLS_ROOTCERT_FILE=$ORG2_TLS
expect 2b "officer1 asks the Auditor's peer for the piece (not a collection member)" \
  "$(query GetAuthorityShare "$RELEASED_HASH")" "private data matching public hash version is not available"

echo "== Police with one piece"
as 3 officer1@simpolice.example.com
pieces=$(query GetAuthorityShare "$UNREQUESTED_HASH")
held=$(jq '1 + (.released | length)' <<<"$pieces" 2>/dev/null || echo "?")
need=$(jq '.threshold' <<<"$pieces" 2>/dev/null || echo "?")
expect 3a "officer1 holds pieces for a clip nobody released ($held held, $need needed)" \
  "$( [ "$held" -lt "$need" ] 2>/dev/null && echo "only $held of $need pieces held")" "only 1 of 2 pieces held"
expect 3b "officer1 records 'opened' for that clip" \
  "$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- RecordAccess "$UNREQUESTED_HASH" opened "")" \
  "No released access request for this clip"

echo "== Self-approval"
as 3 officer1@simpolice.example.com
expect 4a "officer1 releases a piece for their own request 2" \
  "$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- ReleaseShare "$REQ2" "$NODE" "$X" "$PIECE_HASH" "$SIG")" \
  "Only Org1MSP may release key pieces"
as 1 Admin@org1.example.com
expect 4b "a correctly signed release endorsed by JusticeChain + SimPolice, without the Auditor" \
  "$(invoke "${ORG1_PEER[@]}" "${POLICE_PEER[@]}" -- ReleaseShare "$REQ2" "$NODE" "$X" "$PIECE_HASH" "$SIG")" \
  "ENDORSEMENT_POLICY_FAILURE"

echo "== Release without a valid signature"
as 1 Admin@org1.example.com
expect 5a "the guardian's signature reused for a different piece" \
  "$(invoke "${ORG1_PEER[@]}" "${ORG2_PEER[@]}" -- ReleaseShare "$REQ2" "$NODE" "$((X + 1))" "$PIECE_HASH" "$SIG")" \
  "not signed by the releaser"
expect 5b "a made-up signature" \
  "$(invoke "${ORG1_PEER[@]}" "${ORG2_PEER[@]}" -- ReleaseShare "$REQ2" "$NODE" "$X" "$PIECE_HASH" "$(head -c 65 /dev/urandom | od -An -tx1 | tr -d ' \n')")" \
  "not signed by the releaser|could not be recovered"
quiet setGlobals 1
expect 5c "request 2 is still open after all of the above" \
  "$(query GetAccessRequest "$REQ2" | jq -r '"status " + .status')" "status open"

echo "== SimPolice removed (registry revoke, then restored)"
as 1 Admin@org1.example.com
expect 6a "JusticeChain and the Auditor revoke SimPolice" \
  "$(invoke "${ORG1_PEER[@]}" "${ORG2_PEER[@]}" -- RevokeAuthority SimPoliceMSP)" "status \(VALID\)"
as 3 officer1@simpolice.example.com
expect 6b "officer1 requests access after the revoke" \
  "$(invoke "${POLICE_PEER[@]}" "${ORG1_PEER[@]}" -- RequestAccess "$UNREQUESTED_HASH" reason REF)" \
  "Only an active registered authority's officer may do this"
expect 6c "officer1 reads a key piece after the revoke" \
  "$(query GetAuthorityShare "$RELEASED_HASH")" "Only an active registered authority's officer may do this"
quiet setGlobals 1
expect 6d "the registry shows SimPolice as revoked" \
  "$(query GetAuthority SimPoliceMSP | jq -r '"revoked " + (.revoked | tostring)')" "revoked true"
echo "  ...restoring SimPolice with the same desk key"
bash "$REPO/fabric/network/register-authority.sh" >/dev/null 2>&1
as 3 officer1@simpolice.example.com
expect 6e "after re-registering, officer1 can read the piece again" \
  "$(query GetAuthorityShare "$RELEASED_HASH" | jq -r '"found " + (.found | tostring)')" "found true"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
