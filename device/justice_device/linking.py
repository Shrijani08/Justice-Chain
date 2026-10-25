"""Linking the device to its owner's phone, and the formats both sides sign.

The phone scans the device's QR (same fields as the app's pairing QR, plus
"kind": "sos-device"), signs an owner certificate, and posts a setup package
for the device to the gateway, sealed so only the device can read it. The
device collects it, checks both signatures, and saves the owner and her
guardians. The first owner is trusted on first use; after that only a
package from the same owner is accepted.

Signed texts (Ed25519 over UTF-8), mirrored in lib/core/device_link_service.dart
and fabric/gateway/device.js:
  certificate  justice-chain/device-owner/v1|device|deviceEd25519|deviceX25519|deviceAddress|owner|issuedAt
  setup        justice-chain/device-setup/v1|device|owner|issuedAt|sha256(sealed bytes)
  piece        justice-chain/device-piece/v1|manifestHash|owner|device|guardian|pieceHash
"""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey

from . import crypto_compat as cc
from .identity import DEFAULT_KEYS_DIR, Identity
from .sealer import write_atomic
from .settings import SETTINGS_FILE

SETUP_INFO = b"justice-chain-device-setup-v1"
CERTIFICATE_FILE = "certificate.json"


def qr_payload(identity: Identity) -> str:
    """The text in the device's QR code, in the app's pairing-QR format."""
    return json.dumps({
        "kind": "sos-device",
        "node_id": identity.node_id,
        "public_key": cc.b64(identity.ed25519_public),
        "x25519_public_key": cc.b64(identity.x25519_public),
        "anchoring_address": identity.anchoring_address,
    }, separators=(",", ":"))


def certificate_payload(cert: dict) -> str:
    return "|".join([
        "justice-chain/device-owner/v1",
        cert["deviceNodeId"],
        cert["deviceEd25519"],
        cert["deviceX25519"],
        cert["deviceAnchoringAddress"].lower(),
        cert["ownerNodeId"],
        str(cert["issuedAt"]),
    ])


def setup_payload(device_node_id: str, owner_node_id: str, issued_at: int, sealed_b64: str) -> str:
    sealed_hash = hashlib.sha256(base64.b64decode(sealed_b64)).hexdigest()
    return f"justice-chain/device-setup/v1|{device_node_id}|{owner_node_id}|{issued_at}|{sealed_hash}"


def piece_payload(manifest_hash: str, owner: str, device: str, guardian: str, piece_hash: str) -> str:
    return f"justice-chain/device-piece/v1|{manifest_hash}|{owner}|{device}|{guardian}|{piece_hash}"


def sign_text(identity: Identity, text: str) -> str:
    return cc.b64(Ed25519PrivateKey.from_private_bytes(identity.ed25519_seed).sign(text.encode("utf-8")))


def verify_text(public_key_b64: str, text: str, signature_b64: str) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(cc.unb64(public_key_b64)).verify(cc.unb64(signature_b64), text.encode("utf-8"))
        return True
    except Exception:
        return False


def _setup_key(own_x25519_private: bytes, other_x25519_public: bytes) -> bytes:
    raw = X25519PrivateKey.from_private_bytes(own_x25519_private).exchange(
        X25519PublicKey.from_public_bytes(other_x25519_public)
    )
    return cc._hkdf(raw, SETUP_INFO, cc.KEY_LENGTH)


def seal_setup(package: dict, owner_x25519_private: bytes, device_x25519_public: bytes) -> str:
    """What the phone does; here for tests and tools."""
    return cc.b64(cc.aes_encrypt(_setup_key(owner_x25519_private, device_x25519_public), json.dumps(package).encode()))


def open_setup(sealed_b64: str, identity: Identity, owner_x25519_public: bytes) -> dict:
    return json.loads(cc.aes_decrypt(_setup_key(identity.x25519_private, owner_x25519_public), cc.unb64(sealed_b64)))


class SetupRejected(Exception):
    pass


def check_certificate(cert: dict, identity: Identity, owner_ed25519: str) -> None:
    mine = {
        "deviceNodeId": identity.node_id,
        "deviceEd25519": cc.b64(identity.ed25519_public),
        "deviceX25519": cc.b64(identity.x25519_public),
        "deviceAnchoringAddress": identity.anchoring_address.lower(),
    }
    for field, value in mine.items():
        if str(cert.get(field, "")).lower() != value.lower():
            raise SetupRejected(f"the owner certificate is for another device ({field})")
    if not verify_text(owner_ed25519, certificate_payload(cert), cert.get("signature", "")):
        raise SetupRejected("the owner certificate isn't signed by the owner")


def accept_setup(envelope: dict, identity: Identity, keys_dir: Path = DEFAULT_KEYS_DIR) -> dict | None:
    """Checks a setup envelope from the gateway and saves it. Returns the
    saved settings, or None when it is not newer than what the device has.
    Raises SetupRejected when it doesn't check out."""
    owner_ed = envelope["ownerEd25519"]
    owner_id = envelope["ownerNodeId"]
    issued_at = int(envelope["issuedAt"])
    if cc.node_id(cc.unb64(owner_ed)) != owner_id:
        raise SetupRejected("the owner's ID doesn't match her key")
    if envelope.get("deviceNodeId") != identity.node_id:
        raise SetupRejected("the package is for another device")
    if not verify_text(owner_ed, setup_payload(identity.node_id, owner_id, issued_at, envelope["sealed"]), envelope["signature"]):
        raise SetupRejected("the package isn't signed by its owner")

    cert_path = keys_dir / CERTIFICATE_FILE
    if cert_path.exists():
        current = json.loads(cert_path.read_text())
        if current["ownerEd25519"] != owner_ed:
            raise SetupRejected("the device is already linked to someone else")
        if issued_at <= int(current.get("setupIssuedAt", 0)):
            return None

    package = open_setup(envelope["sealed"], identity, cc.unb64(envelope["ownerX25519"]))
    owner = package["owner"]
    if owner.get("nodeId") != owner_id or owner.get("ed25519Public") != owner_ed:
        raise SetupRejected("the package names a different owner")
    certificate = package["certificate"]
    if certificate.get("ownerNodeId") != owner_id:
        raise SetupRejected("the certificate names a different owner")
    check_certificate(certificate, identity, owner_ed)

    settings = {
        "owner": {
            "nodeId": owner_id,
            "username": owner.get("username", ""),
            "x25519Public": owner["x25519Public"],
        },
        "guardians": [
            {"nodeId": g["nodeId"], "name": g.get("name", ""), "x25519Public": g["x25519Public"]}
            for g in package.get("guardians", [])
            if g.get("nodeId") and g.get("x25519Public")
        ],
        "allowSingleGuardian": bool(package.get("allowSingleGuardian", False)),
    }
    write_atomic(keys_dir / SETTINGS_FILE, json.dumps(settings, indent=2).encode())
    write_atomic(cert_path, json.dumps({
        "certificate": certificate,
        "ownerEd25519": owner_ed,
        "setupIssuedAt": issued_at,
    }, indent=2).encode())
    return settings


def load_certificate(keys_dir: Path = DEFAULT_KEYS_DIR) -> dict | None:
    path = keys_dir / CERTIFICATE_FILE
    return json.loads(path.read_text())["certificate"] if path.exists() else None
