#!/usr/bin/env bash
# Makes a restore bundle of the whole Sakshya ledger on the cloud machine:
# the four ledger volumes, the Fabric folder (certificates, CA keys,
# chaincode package) and the gateway's state (mailbox, device setup, keys).
# Fabric stops for about a minute so the copy is consistent.
#
#   ssh -i ~/.ssh/azure_sakshya sakshya@<ip> 'bash -s' < fabric/cloud/backup.sh
#   scp -i ~/.ssh/azure_sakshya sakshya@<ip>:sakshya-backup-*.tgz <safe place>
#
# The bundle holds private keys: keep it off the repo and off shared drives.
# restore.sh puts it back on a fresh machine.
set -euo pipefail

STAMP=$(date -u +%Y%m%d-%H%M)
WORK=$(mktemp -d)
OUT=~/sakshya-backup-$STAMP.tgz
VOLUMES=(compose_orderer.example.com compose_peer0.org1.example.com
  compose_peer0.org2.example.com compose_peer0.simpolice.example.com)

sudo systemctl stop sakshya-tunnel sakshya-gateway sakshya-portal sakshya-fabric
for v in "${VOLUMES[@]}"; do
  sudo docker run --rm -v "$v":/v -v "$WORK":/out alpine tar czpf "/out/vol_$v.tgz" -C /v .
done
sudo tar czpf "$WORK/fabric-samples.tgz" --numeric-owner -C /home/sara_khurshida/fabric \
  --exclude=fabric-samples/bin --exclude=fabric-samples/.git fabric-samples cc
tar czpf "$WORK/gateway-state.tgz" -C ~/sakshya/gateway api-key.txt pinata-jwt.txt tunnel.txt mailbox device-setup
sudo systemctl start sakshya-fabric sakshya-gateway sakshya-portal sakshya-tunnel

(cd "$WORK" && sha256sum ./*.tgz > SHA256SUMS)
tar czf "$OUT" -C "$WORK" .
sudo rm -rf "$WORK"
for _ in $(seq 1 30); do curl -s localhost:8800/health >/dev/null && break; sleep 2; done
echo "Backup: $OUT ($(du -h "$OUT" | cut -f1)); ledger height $(curl -s localhost:8800/health | jq .height)"
