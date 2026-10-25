"""Locks a freshly recorded clip, as the app's EvidenceEncryptor does.

Hashes the clip, encrypts it with a new per-incident AES-256-GCM key, signs
the hash, keeps the key wrapped under the device's vault key, gives each
guardian one sealed Shamir piece, seals the whole key for the owner's phone,
and deletes the plaintext. Afterwards only <hash>.enc and <hash>.json exist.

Record fields match the app's vault records (evidence_vault_service.dart),
plus the device's public keys, which a guardian needs to unseal its piece
and check the signature, and the owner's sealed key ("ownerKey"): a sealed
share with x = 0 whose y is the full key, so the phone can open it with the
same unseal code it uses for guardian pieces.
"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from . import crypto_compat as cc
from .identity import Identity

OWNER_SHARE_X = 0


def threshold_for(guardian_count: int, allow_single_guardian: bool) -> int:
    """As the app's thresholdFor: 1 only when the owner opted into single-guardian mode."""
    if allow_single_guardian and guardian_count < cc.GUARDIAN_QUORUM:
        return 1
    return cc.GUARDIAN_QUORUM


def write_atomic(path: Path, data: bytes) -> None:
    temp = path.with_name(path.name + ".tmp")
    with open(temp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def seal_clip(
    clip_path: Path,
    identity: Identity,
    out_dir: Path,
    guardians: list[dict] = (),
    owner: dict | None = None,
    allow_single_guardian: bool = False,
    captured_at: datetime | None = None,
) -> dict:
    """Seals clip_path into out_dir and deletes it. Returns the saved record."""
    out_dir.mkdir(parents=True, exist_ok=True)
    plaintext = clip_path.read_bytes()
    plaintext_hash = hashlib.sha256(plaintext).hexdigest()
    key = os.urandom(cc.KEY_LENGTH)

    cipher_path = out_dir / f"{plaintext_hash}.enc"
    write_atomic(cipher_path, cc.aes_encrypt(key, plaintext))
    del plaintext

    threshold = threshold_for(len(guardians), allow_single_guardian)
    coefficients = cc.share_coefficients(key, threshold)
    guardian_shares = {}
    next_x = 1
    for guardian in guardians:
        y = cc.share_at(key, coefficients, next_x)
        guardian_shares[guardian["nodeId"]] = cc.seal_share(
            next_x, y, identity.x25519_private, cc.unb64(guardian["x25519Public"])
        )
        next_x += 1

    record = {
        "hash": plaintext_hash,
        "file": cipher_path.name,
        "signature": cc.sign_hash(identity.ed25519_seed, plaintext_hash),
        "wrappedKey": cc.b64(cc.aes_encrypt(identity.vault_key, key)),
        "guardianShares": guardian_shares,
        "nextShareX": next_x,
        "threshold": threshold,
        "nodeId": identity.node_id,
        "deviceEd25519Public": cc.b64(identity.ed25519_public),
        "deviceX25519Public": cc.b64(identity.x25519_public),
        "timestamp": (captured_at or datetime.now(timezone.utc)).isoformat(),
        "source": "sos-device",
        "status": "locally_secured",
        "cid": None,
    }
    if owner is not None:
        record["ownerNodeId"] = owner.get("nodeId")
        record["ownerKey"] = cc.seal_share(
            OWNER_SHARE_X, key, identity.x25519_private, cc.unb64(owner["x25519Public"])
        )

    write_atomic(out_dir / f"{plaintext_hash}.json", json.dumps(record, indent=2).encode())
    clip_path.unlink()
    return record


def open_with_guardian_keys(record: dict, cipher: bytes, guardian_privates: dict[str, bytes]) -> bytes:
    """Opens a sealed clip as guardians would: unseal pieces, rebuild the key,
    decrypt, then check the hash and the device's signature."""
    sender = cc.unb64(record["deviceX25519Public"])
    shares = [
        cc.unseal_share(sealed, guardian_privates[node_id], sender)
        for node_id, sealed in record["guardianShares"].items()
        if node_id in guardian_privates
    ]
    key = cc.recover_incident_key(shares, record["threshold"])
    return _decrypt_and_check(record, cipher, key)


def open_with_owner_key(record: dict, cipher: bytes, owner_x25519_private: bytes) -> bytes:
    x, key = cc.unseal_share(record["ownerKey"], owner_x25519_private, cc.unb64(record["deviceX25519Public"]))
    if x != OWNER_SHARE_X:
        raise ValueError("Not an owner key.")
    return _decrypt_and_check(record, cipher, key)


def _decrypt_and_check(record: dict, cipher: bytes, key: bytes) -> bytes:
    plaintext = cc.aes_decrypt(key, cipher)
    if hashlib.sha256(plaintext).hexdigest() != record["hash"]:
        raise ValueError("The clip does not match its record.")
    if not cc.verify_hash_signature(cc.unb64(record["deviceEd25519Public"]), record["hash"], record["signature"]):
        raise ValueError("The device's signature does not verify.")
    return plaintext
