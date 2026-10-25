"""Uploading and anchoring locked clips, with fake Pinata and gateway services."""

import json
import os

import pytest

from justice_device import crypto_compat as cc
from justice_device import identity, outbox, sealer
from justice_device.network import LedgerRefused, ServiceError


class FakePinata:
    def __init__(self, fail=False):
        self.fail = fail
        self.uploads = []

    def upload(self, path):
        if self.fail:
            raise ServiceError("offline")
        self.uploads.append(path.read_bytes())
        return f"Qm{len(self.uploads)}"


class FakeGateway:
    def __init__(self, fail=False, refuse=False):
        self.fail = fail
        self.refuse = refuse
        self.ledger = {}

    def verify(self, manifest_hash):
        if self.fail:
            raise ServiceError("offline")
        found = manifest_hash in self.ledger
        return {"found": found, **({"blockNumber": 7} if found else {})}

    def anchor(self, manifest_hash, cid, captured_at, node_id, signature):
        if self.refuse:
            raise LedgerRefused("Evidence already stored")
        assert len(signature) == 130
        self.ledger[manifest_hash] = (cid, captured_at, node_id, signature)
        return f"tx-{len(self.ledger)}"


@pytest.fixture
def device(tmp_path):
    return identity.load_or_create(tmp_path / "keys")


def locked_clip(tmp_path, device, name="sos.mp4"):
    clip = tmp_path / name
    clip.write_bytes(os.urandom(5000))
    return sealer.seal_clip(clip, device, tmp_path / "evidence")


def saved(tmp_path, record):
    return json.loads((tmp_path / "evidence" / f"{record['hash']}.json").read_text())


def test_clip_is_uploaded_then_anchored_with_the_device_signature(tmp_path, device):
    record = locked_clip(tmp_path, device)
    pinata, gateway = FakePinata(), FakeGateway()

    assert outbox.process_all(tmp_path / "evidence", device, pinata, gateway) == 0

    after = saved(tmp_path, record)
    assert after["status"] == "anchored" and after["cid"] == "Qm1" and after["anchorTxId"] == "tx-1"
    assert pinata.uploads == [(tmp_path / "evidence" / record["file"]).read_bytes()]
    cid, captured_at, node_id, signature = gateway.ledger[record["hash"]]
    assert cid == "Qm1" and node_id == device.node_id
    assert cc.recover_anchor_signer(record["hash"], signature) == device.anchoring_address


def test_offline_keeps_the_clip_waiting_and_a_later_pass_finishes_it(tmp_path, device):
    record = locked_clip(tmp_path, device)
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(fail=True), FakeGateway()) == 1
    assert saved(tmp_path, record)["status"] == "locally_secured"

    pinata = FakePinata()
    assert outbox.process_all(tmp_path / "evidence", device, pinata, FakeGateway(fail=True)) == 1
    assert saved(tmp_path, record)["status"] == "uploaded_to_ipfs"

    # Back online: the upload is not repeated, only the anchor is done.
    assert outbox.process_all(tmp_path / "evidence", device, pinata, FakeGateway()) == 0
    assert len(pinata.uploads) == 1
    assert saved(tmp_path, record)["status"] == "anchored"


def test_an_anchor_that_already_landed_is_not_sent_again(tmp_path, device):
    record = locked_clip(tmp_path, device)
    gateway = FakeGateway()
    gateway.ledger[record["hash"]] = ("Qm1", 0, device.node_id, "x")
    gateway.refuse = True  # anchoring again would be refused
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), gateway) == 0
    assert saved(tmp_path, record)["status"] == "anchored"


def test_a_refused_clip_stops_retrying(tmp_path, device):
    record = locked_clip(tmp_path, device)
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), FakeGateway(refuse=True)) == 0
    after = saved(tmp_path, record)
    assert after["status"] == "refused" and "already stored" in after["refusal"]


def test_every_waiting_clip_goes_through(tmp_path, device):
    first = locked_clip(tmp_path, device, "a.mp4")
    second = locked_clip(tmp_path, device, "b.mp4")
    gateway = FakeGateway()
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), gateway) == 0
    assert set(gateway.ledger) == {first["hash"], second["hash"]}


class PieceGateway(FakeGateway):
    def __init__(self, refuse_pieces=False):
        super().__init__()
        self.refuse_pieces = refuse_pieces
        self.pieces = []

    def send_piece(self, envelope):
        if self.refuse_pieces:
            raise LedgerRefused("not on the guardian list")
        self.pieces.append(envelope)
        return {"id": "x"}


def linked_clip(tmp_path, device, guardian_count=2):
    owner = {"nodeId": "0" * 16, "x25519Public": cc.b64(cc.x25519_public(os.urandom(32)))}
    guardians = [
        {"nodeId": f"{i}" * 16, "x25519Public": cc.b64(cc.x25519_public(os.urandom(32)))}
        for i in range(1, guardian_count + 1)
    ]
    clip = tmp_path / "linked.mp4"
    clip.write_bytes(os.urandom(5000))
    record = sealer.seal_clip(clip, device, tmp_path / "evidence", guardians=guardians, owner=owner)
    return record, {"ownerNodeId": owner["nodeId"], "deviceNodeId": device.node_id}


def test_each_guardian_gets_their_signed_piece_once(tmp_path, device):
    from justice_device import linking

    record, certificate = linked_clip(tmp_path, device)
    gateway = PieceGateway()
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), gateway, certificate) == 0
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), gateway, certificate) == 0

    assert sorted(e["toNodeId"] for e in gateway.pieces) == sorted(record["guardianShares"])
    envelope = gateway.pieces[0]
    assert envelope["certificate"] == certificate and envelope["victimNodeId"] == "0" * 16
    assert envelope["share"]["cid"] == "Qm1" and envelope["share"]["quorum"] == 2
    payload = linking.piece_payload(record["hash"], "0" * 16, device.node_id, envelope["toNodeId"], envelope["pieceHash"])
    assert linking.verify_text(envelope["share"]["deviceEd25519"], payload, envelope["signature"])


def test_clips_for_a_test_owner_are_not_sent(tmp_path, device):
    locked_clip(tmp_path, device)
    gateway = PieceGateway()
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), gateway, {"ownerNodeId": "f" * 16}) == 0
    assert gateway.pieces == []


def test_a_refused_piece_is_not_retried_forever(tmp_path, device):
    record, certificate = linked_clip(tmp_path, device, guardian_count=1)
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), PieceGateway(refuse_pieces=True), certificate) == 0
    assert list(saved(tmp_path, record)["piecesRefused"]) == list(record["guardianShares"])


def test_the_device_deletes_its_copy_once_the_guardians_hold_their_pieces(tmp_path, device):
    record, certificate = linked_clip(tmp_path, device)
    cipher = tmp_path / "evidence" / record["file"]
    assert outbox.process_all(tmp_path / "evidence", device, FakePinata(), PieceGateway(), certificate) == 0

    after = saved(tmp_path, record)
    assert not cipher.exists()
    assert after["localCopyDeleted"] is True and "wrappedKey" not in after
    assert after["ownerKey"] and after["guardianShares"]  # sealed for others, still deliverable


def test_the_device_keeps_its_copy_while_a_guardian_lacks_a_piece(tmp_path, device):
    record, certificate = linked_clip(tmp_path, device, guardian_count=1)
    cipher = tmp_path / "evidence" / record["file"]
    outbox.process_all(tmp_path / "evidence", device, FakePinata(), PieceGateway(refuse_pieces=True), certificate)
    assert cipher.exists() and "wrappedKey" in saved(tmp_path, record)


def test_test_clips_never_sent_to_guardians_are_kept(tmp_path, device):
    record = locked_clip(tmp_path, device)
    outbox.process_all(tmp_path / "evidence", device, FakePinata(), PieceGateway(), {"ownerNodeId": "f" * 16})
    assert (tmp_path / "evidence" / record["file"]).exists()
