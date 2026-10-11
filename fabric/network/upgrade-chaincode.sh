#!/usr/bin/env bash
# Installs justiceledger on every peer and commits the next chaincode
# definition, approved by all three orgs (Org1, Org2 = Auditor, SimPolice).
#
#   upgrade-chaincode.sh            re-commit the package already installed
#                                   (step 5: SimPolice joins the definition)
#   upgrade-chaincode.sh 1.1        package fabric/chaincode/justiceledger from
#                                   the repo as version 1.1 and commit it
#
# COLLECTIONS=/path/collections_config.json adds a private data collection
# config (step 8). Run inside WSL, e.g.
#   bash /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/upgrade-chaincode.sh 1.1
set -eo pipefail

VERSION=$1
CHANNEL=${CHANNEL:-evidence-channel}
CC=justiceledger
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
REPO_CC=$(cd "$(dirname "$0")/../chaincode/$CC" && pwd)
STAGE=$HOME/fabric/cc/$CC
ORGS="1 2 3"
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config

cd "$TN"
. scripts/envVar.sh
quiet() { "$@" >/dev/null 2>&1; }

quiet setGlobals 1
committed=$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n "$CC" -O json)
CURRENT_SEQ=$(jq -r '.sequence' <<<"$committed")
CURRENT_VERSION=$(jq -r '.version' <<<"$committed")
SEQ=$((CURRENT_SEQ + 1))

# 1. The package to commit.
if [ -z "$VERSION" ]; then
  VERSION=$CURRENT_VERSION
  PKG=$TN/$CC.tar.gz
  [ -f "$PKG" ] || { echo "No $PKG to re-use; pass a version to package the repo." >&2; exit 1; }
else
  # Repo copy without node_modules and tests, as for the first deploy.
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  (cd "$REPO_CC" && tar --exclude=node_modules --exclude=test -cf - .) | (cd "$STAGE" && tar -xf -)
  PKG=$TN/${CC}_$VERSION.tar.gz
  peer lifecycle chaincode package "$PKG" --path "$STAGE" --lang node --label "${CC}_$VERSION"
fi
PKG_ID=$(peer lifecycle chaincode calculatepackageid "$PKG")
echo "Committing $CC version $VERSION, sequence $SEQ, package $PKG_ID"

# 2. Install wherever it is missing.
for org in $ORGS; do
  quiet setGlobals "$org"
  if peer lifecycle chaincode queryinstalled -O json | jq -e --arg id "$PKG_ID" \
       '.installed_chaincodes[]? | select(.package_id == $id)' >/dev/null; then
    echo "org$org: already installed"
  else
    echo "org$org: installing"
    peer lifecycle chaincode install "$PKG"
  fi
done

COLL_ARGS=()
[ -n "$COLLECTIONS" ] && COLL_ARGS=(--collections-config "$COLLECTIONS")
ORDERER_ARGS=(-o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA")

# 3. Every org approves the same definition.
for org in $ORGS; do
  quiet setGlobals "$org"
  peer lifecycle chaincode approveformyorg "${ORDERER_ARGS[@]}" --channelID "$CHANNEL" --name "$CC" \
    --version "$VERSION" --package-id "$PKG_ID" --sequence "$SEQ" "${COLL_ARGS[@]}"
done

quiet setGlobals 1
peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name "$CC" --version "$VERSION" \
  --sequence "$SEQ" "${COLL_ARGS[@]}" --output json

# 4. Commit, endorsed by every peer.
PEER_ARGS=()
for org in $ORGS; do
  quiet setGlobals "$org"
  PEER_ARGS+=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")
done
quiet setGlobals 1
peer lifecycle chaincode commit "${ORDERER_ARGS[@]}" --channelID "$CHANNEL" --name "$CC" \
  --version "$VERSION" --sequence "$SEQ" "${COLL_ARGS[@]}" "${PEER_ARGS[@]}"

# 5. Every peer must report the new definition.
for org in $ORGS; do
  quiet setGlobals "$org"
  seen=$(peer lifecycle chaincode querycommitted -C "$CHANNEL" -n "$CC" -O json | jq -r '.sequence')
  [ "$seen" = "$SEQ" ] || { echo "org$org reports sequence $seen, expected $SEQ" >&2; exit 1; }
done
echo "Committed $CC $VERSION sequence $SEQ on all peers."
