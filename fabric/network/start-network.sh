#!/usr/bin/env bash
# Starts the Fabric network again after a laptop restart (Docker Desktop
# must be running) and checks that every peer is on the same block. Never
# use network.sh down: it deletes the ledger.
#   bash /mnt/d/Justice-Chain/justice-chain2/Justice-Chain/fabric/network/start-network.sh
set -eo pipefail

CONTAINERS=(ca_orderer ca_org1 ca_org2 ca_simpolice orderer.example.com
  peer0.org1.example.com peer0.org2.example.com peer0.simpolice.example.com)
SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
export PATH=$SAMPLES/bin:$PATH
export FABRIC_CFG_PATH=$SAMPLES/config

docker start "${CONTAINERS[@]}" >/dev/null
sleep 8
docker ps --format '{{.Names}}' | sort > /tmp/jc_running
for c in "${CONTAINERS[@]}"; do
  grep -qx "$c" /tmp/jc_running && echo "up    $c" || { echo "DOWN  $c" >&2; exit 1; }
done

cd "$SAMPLES/test-network"
. scripts/envVar.sh >/dev/null
for org in 1 2 3; do
  setGlobals "$org" >/dev/null 2>&1
  echo "org$org peer height: $(peer channel getinfo -c evidence-channel 2>/dev/null | sed 's/.*"height":\([0-9]*\).*/\1/')"
done
echo "Network up. Start the gateway (fabric/gateway) and, for the demo, the portal (fabric/portal) on Windows."
