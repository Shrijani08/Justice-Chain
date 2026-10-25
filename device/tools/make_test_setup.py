"""Makes a test owner and guardians for the device, until linking exists.

Writes two files into the output folder:
  owner.json         public keys only; copy it to ~/.justice-device/ on the Pi
  test_secrets.json  the matching private keys; keep it on the laptop for
                     tools/open_clip.py, never copy it to the Pi

Usage: python tools/make_test_setup.py OUT_DIR [--guardians 2] [--username NAME]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from justice_device import crypto_compat as cc  # noqa: E402


def _person(label: str) -> tuple[dict, dict]:
    ed_seed, x_private = os.urandom(32), os.urandom(32)
    node_id = cc.node_id(cc.ed25519_public(ed_seed))
    public = {"nodeId": node_id, "x25519Public": cc.b64(cc.x25519_public(x_private))}
    secret = {"nodeId": node_id, "label": label, "x25519Private": cc.b64(x_private)}
    return public, secret


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("--guardians", type=int, default=2)
    parser.add_argument("--username", default="test-owner")
    args = parser.parse_args()

    owner, owner_secret = _person("owner")
    owner["username"] = args.username
    guardians, guardian_secrets = [], []
    for i in range(1, args.guardians + 1):
        public, secret = _person(f"guardian {i}")
        public["name"] = f"Test guardian {i}"
        guardians.append(public)
        guardian_secrets.append(secret)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "owner.json").write_text(json.dumps({"owner": owner, "guardians": guardians}, indent=2))
    (args.out_dir / "test_secrets.json").write_text(
        json.dumps({"owner": owner_secret, "guardians": guardian_secrets}, indent=2)
    )
    print(f"Wrote owner.json and test_secrets.json to {args.out_dir}")


if __name__ == "__main__":
    main()
