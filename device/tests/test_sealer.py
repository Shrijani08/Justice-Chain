"""Locking a clip on the device: identity, sealing, and opening it again.

Guardians are checked with the app's own vector keys, so a pass means a
guardian phone can open a device clip with code it already has.
"""

import hashlib
import json
import os
import stat
import sys
from pathlib import Path

import pytest

from justice_device import crypto_compat as cc
from justice_device import identity, sealer, settings

VECTORS = json.loads((Path(__file__).parent / "vectors" / "app_vectors.json").read_text())
APP_GUARDIANS = VECTORS["guardians"]
OWNER_PRIVATE = os.urandom(32)
OWNER = {"nodeId": "owner0000000000", "username": "test", "x25519Public": cc.b64(cc.x25519_public(OWNER_PRIVATE))}


def guardian_list(count):
    return [{"nodeId": g["nodeId"], "x25519Public": g["x25519Public"]} for g in APP_GUARDIANS[:count]]


def guardian_privates():
    return {g["nodeId"]: cc.unb64(g["x25519Private"]) for g in APP_GUARDIANS}


@pytest.fixture
def device(tmp_path):
    return identity.load_or_create(tmp_path / "keys")


@pytest.fixture
def clip(tmp_path):
    path = tmp_path / "work" / "sos.mp4"
    path.parent.mkdir()
    path.write_bytes(os.urandom(200_000))
    return path


def test_identity_is_created_once_and_reloaded(tmp_path):
    first = identity.load_or_create(tmp_path / "keys")
    second = identity.load_or_create(tmp_path / "keys")
    assert first == second
    assert len(first.node_id) == 16
    assert first.anchoring_address.startswith("0x")


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permissions")
def test_identity_file_is_private(tmp_path):
    identity.load_or_create(tmp_path / "keys")
    assert stat.S_IMODE((tmp_path / "keys" / identity.KEYS_FILE).stat().st_mode) == 0o600


def test_sealing_leaves_only_the_locked_clip(device, clip, tmp_path):
    expected_hash = hashlib.sha256(clip.read_bytes()).hexdigest()
    record = sealer.seal_clip(clip, device, tmp_path / "evidence", guardians=guardian_list(3), owner=OWNER)

    assert not clip.exists()
    assert record["hash"] == expected_hash
    assert sorted(p.name for p in (tmp_path / "evidence").iterdir()) == [f"{expected_hash}.enc", f"{expected_hash}.json"]
    assert json.loads((tmp_path / "evidence" / f"{expected_hash}.json").read_text()) == record
    assert record["nodeId"] == device.node_id
    assert record["threshold"] == 2 and record["nextShareX"] == 4


def test_any_two_app_guardians_open_the_clip_but_one_does_not(device, clip, tmp_path):
    original = clip.read_bytes()
    record = sealer.seal_clip(clip, device, tmp_path / "evidence", guardians=guardian_list(3))
    cipher = (tmp_path / "evidence" / record["file"]).read_bytes()
    privates = guardian_privates()
    ids = list(record["guardianShares"])

    for pair in ([ids[0], ids[1]], [ids[1], ids[2]], [ids[0], ids[2]]):
        assert sealer.open_with_guardian_keys(record, cipher, {i: privates[i] for i in pair}) == original
    with pytest.raises(ValueError):
        sealer.open_with_guardian_keys(record, cipher, {ids[0]: privates[ids[0]]})


def test_owner_opens_the_clip_with_her_key(device, clip, tmp_path):
    original = clip.read_bytes()
    record = sealer.seal_clip(clip, device, tmp_path / "evidence", guardians=guardian_list(2), owner=OWNER)
    cipher = (tmp_path / "evidence" / record["file"]).read_bytes()
    assert sealer.open_with_owner_key(record, cipher, OWNER_PRIVATE) == original


def test_device_keeps_its_own_copy_of_the_key(device, clip, tmp_path):
    original = clip.read_bytes()
    record = sealer.seal_clip(clip, device, tmp_path / "evidence")
    key = cc.aes_decrypt(device.vault_key, cc.unb64(record["wrappedKey"]))
    assert cc.aes_decrypt(key, (tmp_path / "evidence" / record["file"]).read_bytes()) == original


def test_signature_and_anchor_match_the_device_keys(device, clip, tmp_path):
    record = sealer.seal_clip(clip, device, tmp_path / "evidence")
    assert cc.verify_hash_signature(device.ed25519_public, record["hash"], record["signature"])
    anchor = cc.sign_anchor(device.anchoring_private_key_hex, record["hash"])
    assert cc.recover_anchor_signer(record["hash"], anchor) == device.anchoring_address


def test_tampered_clip_is_rejected(device, clip, tmp_path):
    record = sealer.seal_clip(clip, device, tmp_path / "evidence", owner=OWNER)
    cipher = bytearray((tmp_path / "evidence" / record["file"]).read_bytes())
    cipher[-1] ^= 1
    with pytest.raises(Exception):
        sealer.open_with_owner_key(record, bytes(cipher), OWNER_PRIVATE)


@pytest.mark.parametrize("count,allow_single,expected", [(0, False, 2), (1, False, 2), (1, True, 1), (2, True, 2)])
def test_threshold_follows_the_app(count, allow_single, expected):
    assert sealer.threshold_for(count, allow_single) == expected


def test_settings_skip_guardians_without_keys(tmp_path):
    (tmp_path / settings.SETTINGS_FILE).write_text(json.dumps({
        "owner": OWNER,
        "guardians": [{"nodeId": "a", "x25519Public": "AAAA"}, {"nodeId": "b"}],
    }))
    loaded = settings.load(tmp_path)
    assert loaded.linked
    assert [g["nodeId"] for g in loaded.guardians] == ["a"]
    assert not settings.load(tmp_path / "missing").linked
