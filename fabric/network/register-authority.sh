#!/usr/bin/env bash
# Step 7: creates SimPolice's evidence desk X25519 key pair and registers
# SimPolice as an authority on the ledger (RegisterAuthority, as the Org1
# admin). Key pieces will be sealed to this key; it is separate from
# SimPolice's Fabric certificates, so reading the ledger is not enough to
# open a piece.
#
# The private key stays in SimPolice's folder in WSL (mode 600), never in
# the repo:
#   organizations/peerOrganizations/simpolice.example.com/evidence-desk/
#     x25519_private.pem   for the officer portal (Step 10)
#     x25519_public.b64    raw 32-byte public key, base64, as on the ledger
#
# Run inside WSL after add-simpolice.sh and a chaincode with RegisterAuthority
# (1.2+). Safe to re-run: an existing desk key is reused, and an existing
# registration with the same key is left alone.
set -eo pipefail

CHANNEL=${CHANNEL:-evidence-channel}
AUTHORITY_MSP=SimPoliceMSP
AUTHORITY_NAME='Demo Police Authority (SIMULATED)'
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
DESK=$TN/organizations/peerOrganizations/simpolice.example.com/evidence-desk
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config

# 1. The desk key pair (kept if it already exists).
mkdir -p "$DESK" && chmod 700 "$DESK"
if [ ! -f "$DESK/x25519_private.pem" ]; then
  (umask 077 && openssl genpkey -algorithm X25519 -out "$DESK/x25519_private.pem")
  echo "Created a new evidence desk key."
fi
# The last 32 bytes of the DER public key are the raw X25519 key.
openssl pkey -in "$DESK/x25519_private.pem" -pubout -outform DER | tail -c 32 | base64 -w0 > "$DESK/x25519_public.b64"
PUBLIC_KEY=$(cat "$DESK/x25519_public.b64")
echo "Evidence desk public key: $PUBLIC_KEY"

cd "$TN"
. scripts/envVar.sh >/dev/null
quiet() { "$@" >/dev/null 2>&1; }

# 2. Already registered?
quiet setGlobals 1
current=$(peer chaincode query -C "$CHANNEL" -n justiceledger -c "{\"Args\":[\"GetAuthority\",\"$AUTHORITY_MSP\"]}")
if [ "$(jq -r '.found and (.revoked | not)' <<<"$current")" = true ]; then
  if [ "$(jq -r '.publicKey' <<<"$current")" = "$PUBLIC_KEY" ]; then
    echo "$AUTHORITY_MSP is already registered with this key; nothing to do."
    exit 0
  fi
  echo "$AUTHORITY_MSP is registered with a different key. Revoke it first (RevokeAuthority)." >&2
  exit 1
fi

# 3. Register as the Org1 admin, endorsed by the Org1 and Org2 peers.
args=$(jq -cn --arg msp "$AUTHORITY_MSP" --arg name "$AUTHORITY_NAME" --arg key "$PUBLIC_KEY" \
  '{Args: ["RegisterAuthority", $msp, $name, $key, "true"]}')
quiet setGlobals 2; ORG2_ADDR=$CORE_PEER_ADDRESS; ORG2_TLS=$CORE_PEER_TLS_ROOTCERT_FILE
quiet setGlobals 1
peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA" \
  -C "$CHANNEL" -n justiceledger -c "$args" --waitForEvent \
  --peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE" \
  --peerAddresses "$ORG2_ADDR" --tlsRootCertFiles "$ORG2_TLS"

peer chaincode query -C "$CHANNEL" -n justiceledger -c "{\"Args\":[\"GetAuthority\",\"$AUTHORITY_MSP\"]}"
echo
