#!/usr/bin/env bash
# Puts the gateway (port 8800) on the internet at the team's fixed ngrok
# address, so phones reach it over mobile data (step 8a). Run it in Git Bash
# after the gateway is running; stop it with Ctrl+C.
#
# One-time setup (DOCS/14-10-2026 remaining steps.md, step 8a):
#   - the ngrok authtoken, added in your own terminal (never in a chat):
#       ngrok config add-authtoken <token>
#     ngrok keeps it in its own config file, outside this repo;
#   - the free static domain from the ngrok dashboard, e.g.
#     xyz.ngrok-free.app, written alone in fabric/gateway/tunnel.txt
#     (git-ignored). GATEWAY_URL in .env is https://<that domain>.
#
# Only the gateway goes through the tunnel. The officer portal (8900)
# stays on localhost: it holds the simulated police key.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN_FILE="$DIR/tunnel.txt"
if [[ ! -s "$DOMAIN_FILE" ]]; then
  echo "Missing $DOMAIN_FILE: put the ngrok static domain in it (e.g. xyz.ngrok-free.app)." >&2
  exit 1
fi
DOMAIN="$(tr -d '[:space:]' < "$DOMAIN_FILE")"
DOMAIN="${DOMAIN#https://}"

if ! curl -s -m 5 http://localhost:8800/health > /dev/null; then
  echo "The gateway isn't answering on port 8800. Start it first: node fabric/gateway/server.js" >&2
  exit 1
fi

NGROK="$(command -v ngrok || echo "$LOCALAPPDATA/Microsoft/WinGet/Links/ngrok.exe")"
echo "Tunnel: https://$DOMAIN -> http://localhost:8800"
# Plain log lines instead of the full-screen view, so it also runs in the
# background (e.g. started by a script) and the log can be kept.
exec "$NGROK" http --url="https://$DOMAIN" 8800 --log=stdout --log-format=logfmt
