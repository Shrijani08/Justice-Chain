"""Opens a locked device clip on the laptop, to check the device's locking.

Uses the test keys from tools/make_test_setup.py. By default it opens the
clip the way guardians do (two key pieces); --owner uses the owner's key.
It checks the clip's hash and the device's signature before writing it.

Usage: python tools/open_clip.py RECORD.json SECRETS.json OUT.mp4 [--owner]
       (the .enc file must sit next to RECORD.json)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from justice_device import crypto_compat as cc  # noqa: E402
from justice_device import sealer  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("record", type=Path)
    parser.add_argument("secrets", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--owner", action="store_true", help="open with the owner's key instead of guardian pieces")
    args = parser.parse_args()

    record = json.loads(args.record.read_text())
    secrets = json.loads(args.secrets.read_text())
    cipher = (args.record.parent / record["file"]).read_bytes()

    if args.owner:
        plaintext = sealer.open_with_owner_key(record, cipher, cc.unb64(secrets["owner"]["x25519Private"]))
        how = "the owner's key"
    else:
        privates = {g["nodeId"]: cc.unb64(g["x25519Private"]) for g in secrets["guardians"]}
        plaintext = sealer.open_with_guardian_keys(record, cipher, privates)
        how = f"{record['threshold']} of {len(record['guardianShares'])} guardian pieces"

    args.out.write_bytes(plaintext)
    print(f"Opened with {how}. Hash and device signature check out. Wrote {args.out} ({len(plaintext) // 1024} KB)")


if __name__ == "__main__":
    main()
