"""The device's own keys and ID, created once on first start.

Same key types as a phone (identity_service.dart): an Ed25519 key that
signs clips and gives the node ID, an X25519 key that seals key pieces for
guardians, a secp256k1 key that signs ledger anchors, and an AES vault key
that keeps the device's own copy of each clip key. They never leave the
device; only the public halves go into records and the QR code.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from eth_account import Account

from . import crypto_compat as cc

DEFAULT_KEYS_DIR = Path.home() / ".justice-device"
KEYS_FILE = "identity.json"


@dataclass(frozen=True)
class Identity:
    ed25519_seed: bytes
    x25519_private: bytes
    anchoring_private_key_hex: str
    vault_key: bytes

    @property
    def ed25519_public(self) -> bytes:
        return cc.ed25519_public(self.ed25519_seed)

    @property
    def x25519_public(self) -> bytes:
        return cc.x25519_public(self.x25519_private)

    @property
    def node_id(self) -> str:
        return cc.node_id(self.ed25519_public)

    @property
    def anchoring_address(self) -> str:
        return cc.anchoring_address(self.anchoring_private_key_hex)

    def public_info(self) -> dict:
        return {
            "nodeId": self.node_id,
            "ed25519Public": cc.b64(self.ed25519_public),
            "x25519Public": cc.b64(self.x25519_public),
            "anchoringAddress": self.anchoring_address,
        }


def _new_identity() -> Identity:
    return Identity(
        ed25519_seed=os.urandom(32),
        x25519_private=os.urandom(32),
        anchoring_private_key_hex=Account.create().key.hex().removeprefix("0x"),
        vault_key=os.urandom(cc.KEY_LENGTH),
    )


def load_or_create(keys_dir: Path = DEFAULT_KEYS_DIR) -> Identity:
    """Loads the device identity, creating and saving it on first start.
    The folder and file are readable by the device's user only."""
    keys_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(keys_dir, 0o700)
    path = keys_dir / KEYS_FILE
    if path.exists():
        data = json.loads(path.read_text())
        return Identity(
            ed25519_seed=cc.unb64(data["ed25519Seed"]),
            x25519_private=cc.unb64(data["x25519Private"]),
            anchoring_private_key_hex=data["anchoringPrivateKey"],
            vault_key=cc.unb64(data["vaultKey"]),
        )

    identity = _new_identity()
    data = {
        "ed25519Seed": cc.b64(identity.ed25519_seed),
        "x25519Private": cc.b64(identity.x25519_private),
        "anchoringPrivateKey": identity.anchoring_private_key_hex,
        "vaultKey": cc.b64(identity.vault_key),
    }
    # Written to a temp file first so a power cut can't leave half a key file.
    temp = path.with_suffix(".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)
    return identity
