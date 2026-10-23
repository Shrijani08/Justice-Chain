"""The device's sealing code must open, and reproduce, what the app makes.

The vectors come from the app itself (test/device_vectors_test.dart), so a
pass here means a guardian's phone and the device agree byte for byte.
"""

import hashlib
import itertools
import json
from pathlib import Path

import pytest

from justice_device import crypto_compat as cc

VECTORS = json.loads((Path(__file__).parent / "vectors" / "app_vectors.json").read_text())
VICTIM = VECTORS["victim"]
CLIP = VECTORS["clip"]
GUARDIANS = VECTORS["guardians"]


def unsealed_shares():
    return [
        cc.unseal_share(
            CLIP["guardianShares"][g["nodeId"]],
            cc.unb64(g["x25519Private"]),
            cc.unb64(VICTIM["x25519Public"]),
        )
        for g in GUARDIANS
    ]


def test_public_keys_node_id_and_address_match_the_app():
    seed = cc.unb64(VICTIM["ed25519Seed"])
    public = cc.ed25519_public(seed)
    assert cc.b64(public) == VICTIM["ed25519Public"]
    assert cc.node_id(public) == VICTIM["nodeId"]
    assert cc.b64(cc.x25519_public(cc.unb64(VICTIM["x25519Private"]))) == VICTIM["x25519Public"]
    assert cc.anchoring_address(VICTIM["anchoringPrivateKey"]) == VICTIM["anchoringAddress"]


def test_hash_signature_is_identical_to_the_app():
    signature = cc.sign_hash(cc.unb64(VICTIM["ed25519Seed"]), CLIP["plaintextHash"])
    assert signature == CLIP["signature"]
    assert cc.verify_hash_signature(
        cc.unb64(VICTIM["ed25519Public"]), CLIP["plaintextHash"], CLIP["signature"]
    )


def test_anchor_signature_is_identical_to_the_app_and_recovers_the_signer():
    signature = cc.sign_anchor(VICTIM["anchoringPrivateKey"], CLIP["plaintextHash"])
    assert signature == CLIP["anchorSignature"]
    assert cc.recover_anchor_signer(CLIP["plaintextHash"], signature) == VICTIM["anchoringAddress"]


def test_each_guardian_unseals_its_own_share():
    assert sorted(x for x, _ in unsealed_shares()) == [1, 2, 3]


@pytest.mark.parametrize("pair", list(itertools.combinations(range(3), 2)))
def test_any_two_guardians_open_the_clip(pair):
    shares = unsealed_shares()
    key = cc.recover_incident_key([shares[i] for i in pair], CLIP["threshold"])
    plaintext = cc.aes_decrypt(key, cc.unb64(CLIP["ciphertext"]))
    assert plaintext == cc.unb64(CLIP["plaintext"])
    assert hashlib.sha256(plaintext).hexdigest() == CLIP["plaintextHash"]


def test_shares_are_reproduced_from_the_key_exactly():
    shares = unsealed_shares()
    key = cc.recover_incident_key(shares[:2], CLIP["threshold"])
    coefficients = cc.share_coefficients(key, CLIP["threshold"])
    for x, y in shares:
        assert cc.share_at(key, coefficients, x) == y


def test_one_share_alone_does_not_open_the_clip():
    shares = unsealed_shares()
    with pytest.raises(ValueError):
        cc.recover_incident_key(shares[:1], CLIP["threshold"])


def test_device_sealed_share_round_trips_to_a_guardian():
    guardian = GUARDIANS[0]
    sealed = cc.seal_share(
        4, b"\x07" * 32, cc.unb64(VICTIM["x25519Private"]), cc.unb64(guardian["x25519Public"])
    )
    assert cc.unseal_share(
        sealed, cc.unb64(guardian["x25519Private"]), cc.unb64(VICTIM["x25519Public"])
    ) == (4, b"\x07" * 32)
