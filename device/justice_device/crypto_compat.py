"""The app's sealing formats, byte for byte, so phones can open device clips.

Mirrors lib/core/evidence_encryptor.dart, lib/core/shamir.dart and the key
handling in lib/core/identity_service.dart and anchoring_service.dart. Any
change here must keep device/tests/test_app_vectors.py passing; those
vectors are produced by the app itself (test/device_vectors_test.dart).
"""

from __future__ import annotations

import base64
import hashlib
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from eth_account import Account
from eth_account.messages import encode_defunct

NONCE_LENGTH = 12
MAC_LENGTH = 16
KEY_LENGTH = 32
GUARDIAN_QUORUM = 2

GUARDIAN_WRAP_INFO = b"justice-chain-guardian-wrap-v1"
SHAMIR_COEFFICIENTS_INFO = b"justice-chain-shamir-coefficients-v1"

_RAW = serialization.Encoding.Raw
_RAW_PUBLIC = serialization.PublicFormat.Raw


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def unb64(text: str) -> bytes:
    return base64.b64decode(text)


# --- AES-256-GCM boxes -------------------------------------------------------
# The app stores a box as nonce(12) + mac(16) + ciphertext; Python's AESGCM
# works with ciphertext + tag, so the tag is moved to the front and back.


def aes_encrypt(key: bytes, plaintext: bytes) -> bytes:
    nonce = os.urandom(NONCE_LENGTH)
    sealed = AESGCM(key).encrypt(nonce, plaintext, None)
    return nonce + sealed[-MAC_LENGTH:] + sealed[:-MAC_LENGTH]


def aes_decrypt(key: bytes, packed: bytes) -> bytes:
    if len(packed) < NONCE_LENGTH + MAC_LENGTH:
        raise ValueError("Packed box too short to contain nonce and MAC.")
    nonce = packed[:NONCE_LENGTH]
    mac = packed[NONCE_LENGTH : NONCE_LENGTH + MAC_LENGTH]
    ciphertext = packed[NONCE_LENGTH + MAC_LENGTH :]
    return AESGCM(key).decrypt(nonce, ciphertext + mac, None)


def _hkdf(secret: bytes, info: bytes, length: int) -> bytes:
    # No salt, as in the app: HKDF then uses a zero-filled salt.
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=None, info=info).derive(secret)


# --- Keys and IDs ------------------------------------------------------------


def ed25519_public(seed: bytes) -> bytes:
    return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(_RAW, _RAW_PUBLIC)


def x25519_public(private: bytes) -> bytes:
    return X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(_RAW, _RAW_PUBLIC)


def node_id(ed25519_public_key: bytes) -> str:
    """First 16 hex characters of SHA-256 of the Ed25519 public key."""
    return hashlib.sha256(ed25519_public_key).hexdigest()[:16]


def anchoring_address(private_key_hex: str) -> str:
    return Account.from_key(private_key_hex).address


# --- Signatures --------------------------------------------------------------


def sign_hash(seed: bytes, plaintext_hash_hex: str) -> str:
    """Ed25519 signature over the UTF-8 bytes of the hex hash, base64."""
    signature = Ed25519PrivateKey.from_private_bytes(seed).sign(plaintext_hash_hex.encode("utf-8"))
    return b64(signature)


def verify_hash_signature(public_key: bytes, plaintext_hash_hex: str, signature_b64: str) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            unb64(signature_b64), plaintext_hash_hex.encode("utf-8")
        )
        return True
    except Exception:
        return False


def sign_anchor(private_key_hex: str, manifest_hash_hex: str) -> str:
    """Ethereum personal-message signature over the raw hash bytes, as the
    app's signAnchor: hex, no 0x prefix, v = 27 or 28."""
    message = encode_defunct(primitive=bytes.fromhex(manifest_hash_hex))
    return Account.sign_message(message, private_key=private_key_hex).signature.hex().removeprefix("0x")


def recover_anchor_signer(manifest_hash_hex: str, signature_hex: str) -> str:
    message = encode_defunct(primitive=bytes.fromhex(manifest_hash_hex))
    return Account.recover_message(message, signature=bytes.fromhex(signature_hex.removeprefix("0x")))


# --- Shamir over GF(2^8), polynomial 0x11b, generator 0x03 -------------------

_EXP = [0] * 510
_LOG = [0] * 256
_value = 1
for _i in range(255):
    _EXP[_i] = _value
    _EXP[_i + 255] = _value
    _LOG[_value] = _i
    _xtime = ((_value << 1) ^ (0x1B if _value & 0x80 else 0)) & 0xFF
    _value ^= _xtime


def _mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _div(a: int, b: int) -> int:
    if b == 0:
        raise ZeroDivisionError("Division by zero in GF(256).")
    if a == 0:
        return 0
    return _EXP[(_LOG[a] - _LOG[b] + 255) % 255]


def share_coefficients(incident_key: bytes, threshold: int) -> list[bytes]:
    if threshold == 1:
        return []
    derived = _hkdf(incident_key, SHAMIR_COEFFICIENTS_INFO, len(incident_key) * (threshold - 1))
    n = len(incident_key)
    return [derived[i * n : (i + 1) * n] for i in range(threshold - 1)]


def share_at(secret: bytes, coefficients: list[bytes], x: int) -> bytes:
    if not 1 <= x <= 255:
        raise ValueError(f"Share index must be in 1..255, got {x}.")
    y = bytearray(len(secret))
    for b in range(len(secret)):
        acc = 0
        for c in reversed(coefficients):
            acc = _mul(acc, x) ^ c[b]
        y[b] = _mul(acc, x) ^ secret[b]
    return bytes(y)


def combine(shares: list[tuple[int, bytes]]) -> bytes:
    if not shares:
        raise ValueError("No shares to combine.")
    xs = [x for x, _ in shares]
    if len(set(xs)) != len(xs):
        raise ValueError("Duplicate share index.")
    length = len(shares[0][1])
    secret = bytearray(length)
    for i, (xi, yi) in enumerate(shares):
        basis = 1
        for j, (xj, _) in enumerate(shares):
            if i != j:
                basis = _mul(basis, _div(xj, xj ^ xi))
        for b in range(length):
            secret[b] ^= _mul(yi[b], basis)
    return bytes(secret)


# --- Sealing key shares for guardians ----------------------------------------


def shared_key(own_x25519_private: bytes, remote_x25519_public: bytes) -> bytes:
    raw = X25519PrivateKey.from_private_bytes(own_x25519_private).exchange(
        X25519PublicKey.from_public_bytes(remote_x25519_public)
    )
    return _hkdf(raw, GUARDIAN_WRAP_INFO, KEY_LENGTH)


def seal_share(x: int, y: bytes, own_x25519_private: bytes, recipient_x25519_public: bytes) -> str:
    key = shared_key(own_x25519_private, recipient_x25519_public)
    return b64(aes_encrypt(key, bytes([x]) + y))


def unseal_share(sealed_b64: str, own_x25519_private: bytes, sender_x25519_public: bytes) -> tuple[int, bytes]:
    key = shared_key(own_x25519_private, sender_x25519_public)
    data = aes_decrypt(key, unb64(sealed_b64))
    return data[0], data[1:]


def recover_incident_key(shares: list[tuple[int, bytes]], threshold: int) -> bytes:
    if len(shares) < threshold:
        raise ValueError(f"Need {threshold} guardian shares to decrypt, got {len(shares)}.")
    if threshold == 1:
        return shares[0][1]
    return combine(shares)
