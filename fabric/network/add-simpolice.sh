#!/usr/bin/env bash
# Step 5 of DOCS/08-10-2026 simulated authority guardian on Fabric design.md:
# adds "SimPolice (SIMULATED)" (SimPoliceMSP, simpolice.example.com) to the
# channel. It follows fabric-samples' addOrg3 flow with Org3 renamed, as the
# design asks, instead of a custom one: a renamed copy of addOrg3/ and
# scripts/org3-scripts/ is made, and the sample's own scripts then create the
# CA and identities, submit the channel config update (signed by Org1 and
# Org2 admins) and join the peer.
#
# Run inside WSL (Docker running, base network up):
#   bash /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/add-simpolice.sh
# Safe to re-run: it stops if SimPoliceMSP is already in the channel.
# No `set -u`: the sample's envVar.sh reads unset variables.
set -eo pipefail

CHANNEL=${CHANNEL:-evidence-channel}
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config

# Shown in every SimPolice certificate, so no one mistakes it for a real force.
CERT_NAMES='C=IN,ST=Karnataka,L=Bengaluru,O=SimPolice (SIMULATED)'

cd "$TN"
. scripts/envVar.sh

channel_has_simpolice() {
  setGlobals 1 >/dev/null
  peer channel fetch config /tmp/jc_config.pb -c "$CHANNEL" -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA" >/dev/null 2>&1
  configtxlator proto_decode --input /tmp/jc_config.pb --type common.Block \
    | jq -e '.data.data[0].payload.data.config.channel_group.groups.Application.groups.SimPoliceMSP' >/dev/null
}

if channel_has_simpolice; then
  echo "SimPoliceMSP is already a member of $CHANNEL; nothing to do."
  exit 0
fi

rename() {
  sed -e 's/org3\.example\.com/simpolice.example.com/g' \
      -e 's/Org3MSP/SimPoliceMSP/g' \
      -e 's/ca-org3/ca-simpolice/g' \
      -e 's/ca_org3/ca_simpolice/g' \
      -e 's/org3admin/simpoliceadmin/g' \
      -e 's#fabric-ca/org3#fabric-ca/simpolice#g' \
      -e 's/org3-scripts/simpolice-scripts/g' \
      -e 's/org3\.json/simpolice.json/g' \
      -e 's/org3_update_in_envelope/simpolice_update_in_envelope/g' \
      -e 's/connection-org3/connection-simpolice/g' \
      -e 's/addOrg3/addSimPolice/g'
}

# 1. Renamed copies of the sample (kept as they are if already made).
if [ ! -d addSimPolice ]; then
  cp -r addOrg3 addSimPolice
  mv addSimPolice/fabric-ca/org3 addSimPolice/fabric-ca/simpolice
  mv addSimPolice/addOrg3.sh addSimPolice/addSimPolice.sh
  find addSimPolice -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.json' \) | while read -r f; do
    rename < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  # The rename above points at ca-simpolice compose files, so rename those.
  find addSimPolice/compose -name '*ca-org3.yaml' | while read -r f; do
    mv "$f" "${f%ca-org3.yaml}ca-simpolice.yaml"
  done
  chmod +x addSimPolice/*.sh

  # The CA's own certificate and every certificate it issues say SIMULATED.
  sed -i -e 's/C: US$/C: IN/' -e 's/^\(\s*\)ST: "North Carolina"$/\1ST: "Karnataka"/' \
         -e 's/^\(\s*\)L: "Raleigh"$/\1L: "Bengaluru"/' \
         -e 's/^\(\s*\)O: simpolice\.example\.com$/\1O: "SimPolice (SIMULATED)"/' \
         addSimPolice/fabric-ca/simpolice/fabric-ca-server-config.yaml
  sed -i "s#fabric-ca-client enroll \(.*\)#fabric-ca-client enroll \1 --csr.names \"$CERT_NAMES\"#" \
         addSimPolice/fabric-ca/registerEnroll.sh
fi
if [ ! -d scripts/simpolice-scripts ]; then
  cp -r scripts/org3-scripts scripts/simpolice-scripts
  for f in scripts/simpolice-scripts/*.sh; do
    rename < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  chmod +x scripts/simpolice-scripts/*.sh
fi

# 2. The shared helpers treat "org 3" as Org3; point them at SimPolice.
for f in scripts/envVar.sh scripts/setAnchorPeer.sh; do
  [ -f "$f.orig" ] || cp "$f" "$f.orig"
  sed -i -e 's/org3\.example\.com/simpolice.example.com/g' -e 's/Org3MSP/SimPoliceMSP/g' "$f"
done

# A path, host or MSP ID still naming org3 would point at the wrong org.
# Function names (createOrg3, Org3Up), log text and envVar.sh's ORG3
# variable names are harmless and stay.
leftover=$(grep -rn -E 'org3\.example|Org3MSP|ca[-_]org3|org3admin|fabric-ca/org3|org3-scripts' \
  addSimPolice scripts/simpolice-scripts scripts/envVar.sh scripts/setAnchorPeer.sh \
  | grep -v -E ':[0-9]+:[[:space:]]*#' || true)
if [ -n "$leftover" ]; then
  echo "Unexpected org3 references left; stopping before touching the channel:" >&2
  echo "$leftover" >&2
  exit 1
fi

if [ "${PREPARE_ONLY:-}" = 1 ]; then
  echo "Prepared addSimPolice/ and scripts/simpolice-scripts/ (PREPARE_ONLY=1, channel untouched)."
  exit 0
fi

# 3. The sample's own flow: CA + identities, config update, join, anchor peer.
cd addSimPolice
./addSimPolice.sh up -c "$CHANNEL" -ca

cd "$TN"
if channel_has_simpolice; then
  echo "SimPoliceMSP added to $CHANNEL."
else
  echo "SimPoliceMSP is not in the channel config after the update." >&2
  exit 1
fi
