"""Uploads through a one-time Pinata URL from the gateway (no Pinata key on the card)."""

import pytest

from justice_device import network


class FakeResponse:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.content = b"x"

    def json(self):
        return self._body


class UrlGateway:
    def __init__(self):
        self.sizes = []

    def upload_url(self, size):
        self.sizes.append(size)
        return "https://uploads.pinata.cloud/v3/files/signed-1"


def test_upload_goes_to_the_signed_url_without_a_key_and_reads_the_v3_cid(tmp_path, monkeypatch):
    clip = tmp_path / "clip.enc"
    clip.write_bytes(b"z" * 300)
    sent = {}

    def fake_post(url, **kwargs):
        sent.update(url=url, **kwargs)
        return FakeResponse(200, {"data": {"cid": "bafkreiabc", "size": 300}})

    monkeypatch.setattr(network.requests, "post", fake_post)
    gateway = UrlGateway()

    assert network.SignedUrlPinata(gateway).upload(clip) == "bafkreiabc"
    assert gateway.sizes == [300]
    assert sent["url"].endswith("/signed-1")
    assert sent["data"] == {"network": "public"}
    assert "headers" not in sent  # no Authorization: the card holds no Pinata key


def test_a_rejected_upload_is_retried_later(tmp_path, monkeypatch):
    clip = tmp_path / "clip.enc"
    clip.write_bytes(b"z")
    monkeypatch.setattr(network.requests, "post", lambda url, **kw: FakeResponse(403, {}))
    with pytest.raises(network.ServiceError):
        network.SignedUrlPinata(UrlGateway()).upload(clip)
