"""Linking: the device accepts its owner's setup package and nobody else's."""

import json
import os

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from justice_device import crypto_compat as cc
from justice_device import identity, linking, settings


class Phone:
    """What the owner's app does when it links a device."""

    def __init__(self, username="riya"):
        self.ed_seed = os.urandom(32)
        self.x_private = os.urandom(32)
        self.ed_public = cc.b64(cc.ed25519_public(self.ed_seed))
        self.node_id = cc.node_id(cc.ed25519_public(self.ed_seed))
        self.username = username

    def sign(self, text):
        return cc.b64(Ed25519PrivateKey.from_private_bytes(self.ed_seed).sign(text.encode()))

    def envelope(self, device, issued_at=1000, guardians=None, cert_device=None):
        qr = json.loads(linking.qr_payload(cert_device or device))
        cert = {
            "deviceNodeId": qr["node_id"],
            "deviceEd25519": qr["public_key"],
            "deviceX25519": qr["x25519_public_key"],
            "deviceAnchoringAddress": qr["anchoring_address"].lower(),
            "ownerNodeId": self.node_id,
            "issuedAt": issued_at,
        }
        cert["signature"] = self.sign(linking.certificate_payload(cert))
        package = {
            "owner": {
                "nodeId": self.node_id,
                "username": self.username,
                "ed25519Public": self.ed_public,
                "x25519Public": cc.b64(cc.x25519_public(self.x_private)),
            },
            "guardians": guardians if guardians is not None else [
                {"nodeId": "a" * 16, "name": "Mom", "x25519Public": cc.b64(cc.x25519_public(os.urandom(32)))},
                {"nodeId": "b" * 16, "name": "Alex", "x25519Public": cc.b64(cc.x25519_public(os.urandom(32)))},
            ],
            "certificate": cert,
            "issuedAt": issued_at,
        }
        sealed = linking.seal_setup(package, self.x_private, device.x25519_public)
        return {
            "found": True,
            "deviceNodeId": device.node_id,
            "ownerNodeId": self.node_id,
            "ownerEd25519": self.ed_public,
            "ownerX25519": cc.b64(cc.x25519_public(self.x_private)),
            "issuedAt": issued_at,
            "sealed": sealed,
            "signature": self.sign(linking.setup_payload(device.node_id, self.node_id, issued_at, sealed)),
        }


@pytest.fixture
def keys(tmp_path):
    return tmp_path / "keys"


@pytest.fixture
def device(keys):
    return identity.load_or_create(keys)


def test_qr_uses_the_app_pairing_fields(device):
    qr = json.loads(linking.qr_payload(device))
    assert qr["kind"] == "sos-device"
    assert qr["node_id"] == device.node_id
    assert cc.unb64(qr["public_key"]) == device.ed25519_public


def test_setup_is_saved_and_the_device_becomes_linked(device, keys):
    phone = Phone()
    saved = linking.accept_setup(phone.envelope(device), device, keys)
    assert saved["owner"]["username"] == "riya"
    loaded = settings.load(keys)
    assert loaded.linked and [g["name"] for g in loaded.guardians] == ["Mom", "Alex"]
    assert linking.load_certificate(keys)["ownerNodeId"] == phone.node_id


def test_an_update_from_the_owner_replaces_the_guardians(device, keys):
    phone = Phone()
    linking.accept_setup(phone.envelope(device, issued_at=1000), device, keys)
    assert linking.accept_setup(phone.envelope(device, issued_at=1000), device, keys) is None
    linking.accept_setup(phone.envelope(device, issued_at=2000, guardians=[]), device, keys)
    assert settings.load(keys).guardians == []


def test_someone_else_cannot_take_over_a_linked_device(device, keys):
    linking.accept_setup(Phone().envelope(device), device, keys)
    with pytest.raises(linking.SetupRejected, match="someone else"):
        linking.accept_setup(Phone("mallory").envelope(device, issued_at=5000), device, keys)


def test_a_certificate_for_another_device_is_rejected(device, keys, tmp_path):
    other = identity.load_or_create(tmp_path / "other")
    with pytest.raises(linking.SetupRejected, match="another device"):
        linking.accept_setup(Phone().envelope(device, cert_device=other), device, keys)


def test_a_tampered_package_is_rejected(device, keys):
    envelope = Phone().envelope(device)
    envelope["issuedAt"] = 9999
    with pytest.raises(linking.SetupRejected, match="signed"):
        linking.accept_setup(envelope, device, keys)
