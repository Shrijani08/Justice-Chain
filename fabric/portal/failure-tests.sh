#!/usr/bin/env bash
# Step 12: failure tests through the officer portal. Each case must stop
# with the right failed check, and a failed open must not be recorded as
# "opened" in the audit trail.
#
# Run from Git Bash on Windows with the portal running against the local
# IPFS stand-in that test/portal_live_test.dart fills:
#   (cd build/portal_ipfs && python -m http.server 8901 --bind 127.0.0.1)
#   (cd fabric/portal && IPFS_GATEWAY=http://127.0.0.1:8901/ npm start)
#   bash fabric/portal/failure-tests.sh
set -eo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PORTAL=${PORTAL:-http://localhost:8900}
STATE=$REPO/build/portal_live_state.json
SHARED=$REPO/build/authority_live_share.json
for f in "$STATE" "$SHARED"; do
  [ -f "$f" ] || { echo "Missing $f: run the Step 8 and Step 10 live tests first." >&2; exit 1; }
done
json() { python -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

HASH=$(json "d['manifestHash']" < "$STATE")
UNRELEASED=$(json "d['manifestHash']" < "$SHARED")
CID=$(curl -s "$PORTAL/api/clips" | json "[c['record']['cid'] for c in d if c['consent']['manifestHash']=='$HASH'][0]")
CLIP=$REPO/build/portal_ipfs/$CID
opened_count() { curl -s "$PORTAL/api/clips/$1/audit" | json "len([e for e in d if e['event']=='opened'])"; }
failed_check() { json "next((c['name'] + ': ' + c['detail']) for c in (d.get('checks') or []) if not c['ok']) if d.get('checks') and not all(c['ok'] for c in d['checks']) else 'no failed check'"; }

passed=0; failed=0
expect() {  # expect <case> <what was tried> <result> <pattern>
  if grep -q -E -- "$4" <<<"$3"; then
    passed=$((passed + 1)); printf '  PASS  %-4s %s\n        -> %s\n' "$1" "$2" "$3"
  else
    failed=$((failed + 1)); printf '  FAIL  %-4s %s\n        got: %s\n' "$1" "$2" "$3"
  fi
}

echo "== Tampered IPFS file"
before=$(opened_count "$HASH")
cp "$CLIP" "$CLIP.orig"
trap 'mv -f "$CLIP.orig" "$CLIP"' EXIT
# Flip one byte in the middle of the ciphertext.
python -c "import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[len(b)//2]^=1; open(p,'wb').write(b)" "$CLIP"
expect 7a "one changed byte in the encrypted clip" \
  "$(curl -s -X POST "$PORTAL/api/clips/$HASH/open" | failed_check)" "^Clip decrypted:"
expect 7b "the failed open is not recorded as 'opened'" \
  "opened $before -> $(opened_count "$HASH")" "^opened $before -> $before$"
mv -f "$CLIP.orig" "$CLIP"; trap - EXIT
expect 7c "the untouched file opens again (all checks pass)" \
  "$(curl -s -X POST "$PORTAL/api/clips/$HASH/open" | json "'all ' + str(len(d['checks'])) + ' checks passed' if all(c['ok'] for c in d['checks']) else 'a check failed'")" \
  "^all [0-9]+ checks passed$"

echo "== Police with one piece"
expect 8a "officer opens a clip nobody released" \
  "$(curl -s -X POST "$PORTAL/api/clips/$UNRELEASED/open" | failed_check)" "^Enough pieces to open: 1 of 2"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
