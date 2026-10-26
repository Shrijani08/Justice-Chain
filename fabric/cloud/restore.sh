#!/usr/bin/env bash
# Rebuilds the Sakshya ledger on a fresh Ubuntu 24.04 machine (2 vCPU,
# 8 GB) from a bundle made by backup.sh, e.g. after moving to another
# Azure for Students account. About 15 minutes.
#
#   scp -i <key> sakshya-backup-*.tgz <repo>/fabric/cloud/restore.sh <user>@<ip>:
#   scp -r -i <key> <repo>/fabric/gateway <repo>/fabric/portal <repo>/fabric/network <user>@<ip>:sakshya-src/
#   ssh -i <key> <user>@<ip> 'bash restore.sh sakshya-backup-*.tgz'
#
# Then copy your ngrok config to ~/.config/ngrok/ngrok.yml and run
# `sudo systemctl start sakshya-tunnel`; stop the tunnel anywhere else
# first (the free plan allows one). Phones, the Pi and the app need no
# change: the address stays https://grandly-riverside-showy.ngrok-free.dev.
set -euo pipefail

BUNDLE=$(realpath "$1")
ME=$(whoami)
FABRIC=/home/sara_khurshida/fabric   # the path the certificates were made under
ORGS=$FABRIC/fabric-samples/test-network/organizations
WORK=$(mktemp -d)
tar xzf "$BUNDLE" -C "$WORK"
(cd "$WORK" && sha256sum -c SHA256SUMS)

# 1. Docker, Node 20, ngrok.
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq >/dev/null
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sudo sh >/dev/null
command -v node >/dev/null || { curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null; sudo apt-get install -y -qq nodejs >/dev/null; }
if ! command -v ngrok >/dev/null; then
  curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
  echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq ngrok >/dev/null
fi

# 2. The same Fabric images the network was built with.
for img in fabric-peer:2.5.16 fabric-orderer:2.5.16 fabric-ca:1.5.17 fabric-ccenv:2.5.16 fabric-baseos:2.5.16 fabric-nodeenv:2.5; do
  sudo docker pull -q "hyperledger/$img" >/dev/null
done
for i in peer orderer ccenv baseos; do
  sudo docker tag "hyperledger/fabric-$i:2.5.16" "hyperledger/fabric-$i:latest"
  sudo docker tag "hyperledger/fabric-$i:2.5.16" "hyperledger/fabric-$i:2.5"
done
sudo docker tag hyperledger/fabric-ca:1.5.17 hyperledger/fabric-ca:latest

# 3. Certificates, CA keys and ledger volumes.
sudo mkdir -p "$FABRIC" && sudo chown -R "$ME:$ME" /home/sara_khurshida
sudo tar xzpf "$WORK/fabric-samples.tgz" --numeric-owner -C "$FABRIC"
(cd "$FABRIC/fabric-samples" && curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh \
  && bash install-fabric.sh --fabric-version 2.5.16 --ca-version 1.5.17 binary >/dev/null 2>&1)
for f in "$WORK"/vol_*.tgz; do
  v=$(basename "$f" .tgz); v=${v#vol_}
  sudo docker volume create "$v" >/dev/null
  sudo docker run --rm -v "$v":/v -v "$WORK":/in alpine tar xzpf "/in/vol_$v.tgz" -C /v
done
sudo chmod -R o+rX "$ORGS"

# 4. The containers, created as on the laptop (compose project "compose").
export DOCKER_SOCK=/var/run/docker.sock
TN=$FABRIC/fabric-samples/test-network
(cd "$TN/compose" && sudo -E docker compose -f compose-ca.yaml up -d \
  && sudo -E docker compose -f compose-test-net.yaml -f docker/docker-compose-test-net.yaml up -d)
(cd "$TN/addSimPolice/compose" && sudo -E docker compose -f compose-ca-simpolice.yaml -f docker/docker-compose-ca-simpolice.yaml up -d \
  && sudo -E docker compose -f compose-org3.yaml -f docker/docker-compose-org3.yaml up -d)

# 5. Gateway and portal, with the gateway's mailbox and keys.
mkdir -p ~/sakshya && cp -r ~/sakshya-src/* ~/sakshya/
tar xzpf "$WORK/gateway-state.tgz" -C ~/sakshya/gateway
chmod 600 ~/sakshya/gateway/api-key.txt ~/sakshya/gateway/pinata-jwt.txt
(cd ~/sakshya/gateway && npm ci --omit=dev --silent) && (cd ~/sakshya/portal && npm ci --omit=dev --silent)

# 6. Services that start everything at boot.
unit() { sudo tee "/etc/systemd/system/$1.service" >/dev/null; }
unit sakshya-fabric <<UNIT
[Unit]
Description=Sakshya Fabric network (8 containers)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start ca_orderer ca_org1 ca_org2 ca_simpolice orderer.example.com peer0.org1.example.com peer0.org2.example.com peer0.simpolice.example.com
ExecStartPost=/bin/sleep 10
ExecStop=/usr/bin/docker stop peer0.simpolice.example.com peer0.org2.example.com peer0.org1.example.com orderer.example.com ca_simpolice ca_org2 ca_org1 ca_orderer
[Install]
WantedBy=multi-user.target
UNIT
for svc in gateway portal; do
unit "sakshya-$svc" <<UNIT
[Unit]
Description=Sakshya $svc
After=sakshya-fabric.service
Requires=sakshya-fabric.service
[Service]
User=$ME
WorkingDirectory=/home/$ME/sakshya/$svc
Environment=FABRIC_ORGS_DIR=$ORGS
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
done
unit sakshya-tunnel <<UNIT
[Unit]
Description=Sakshya ngrok tunnel to the gateway
After=sakshya-gateway.service network-online.target
Wants=network-online.target
ConditionPathExists=/home/$ME/.config/ngrok/ngrok.yml
[Service]
User=$ME
ExecStart=$(command -v ngrok) http --url=https://$(cat ~/sakshya/gateway/tunnel.txt | tr -d '[:space:]') 8800 --log=stdout --log-format=logfmt
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now sakshya-fabric sakshya-gateway sakshya-portal
sudo systemctl enable sakshya-tunnel
sudo rm -rf "$WORK"
sleep 8
echo "Gateway: $(curl -s localhost:8800/health)"
