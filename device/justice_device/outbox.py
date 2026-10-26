"""Gets every locked clip onto IPFS and the ledger, and its key pieces to
the guardians, retrying until it does.

The to-do list is the evidence folder itself: each <hash>.json record moves
locally_secured -> uploaded_to_ipfs -> anchored, as in the app's vault. Once
the device is linked (it holds an owner certificate), each guardian's sealed
piece then goes to their gateway mailbox ("piecesSent"). Once enough
guardians hold their pieces to open the clip, the device deletes its own
encrypted copy and its own key to it ("localCopyDeleted"): its keys sit on
the same card, so whoever takes the device could otherwise open the clip.
The record is saved after every step, so a restart or power cut resumes
where it stopped and never uploads, anchors or sends twice.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime
from pathlib import Path

from . import crypto_compat as cc
from . import linking
from .identity import Identity
from .network import LedgerRefused, ServiceError
from .sealer import write_atomic

DONE = "anchored"
REFUSED = "refused"


def _save(path: Path, record: dict) -> None:
    write_atomic(path, json.dumps(record, indent=2).encode())


def _pieces_due(record: dict, certificate: dict | None) -> list[str]:
    """Guardians still waiting for their piece of an anchored clip. Only clips
    locked for the certificate's owner go out; test clips stay on the card."""
    if certificate is None or record.get("status") != DONE:
        return []
    if record.get("ownerNodeId") != certificate["ownerNodeId"]:
        return []
    done = set(record.get("piecesSent", [])) | set(record.get("piecesRefused", {}))
    return [g for g in record.get("guardianShares", {}) if g not in done]


def _can_drop_local_copy(record: dict) -> bool:
    """True once every guardian holds their piece, enough of them to open
    the clip, so the device's own copy and key are no longer needed."""
    if record.get("localCopyDeleted") or record.get("status") != DONE or not record.get("cid"):
        return False
    sent = set(record.get("piecesSent", []))
    shares = set(record.get("guardianShares", {}))
    return bool(shares) and shares <= sent and len(sent) >= record.get("threshold", cc.GUARDIAN_QUORUM)


def _drop_local_copy(path: Path, record: dict) -> None:
    cipher = path.parent / record["file"]
    if cipher.exists():
        cipher.unlink()
    record.pop("wrappedKey", None)
    record["localCopyDeleted"] = True
    _save(path, record)
    print(f"Deleted the device's copy of {record['hash'][:16]}…: it is on IPFS and the guardians hold their pieces", flush=True)


def pending(evidence_dir: Path, certificate: dict | None = None) -> list[Path]:
    """Records still waiting to upload, anchor, send pieces or clean up, oldest first."""
    if not evidence_dir.exists():
        return []
    paths = []
    for path in sorted(evidence_dir.glob("*.json"), key=lambda p: p.stat().st_mtime):
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if record.get("status") not in (DONE, REFUSED) or _pieces_due(record, certificate) or _can_drop_local_copy(record):
            paths.append(path)
    return paths


def _own_anchor(found: dict, address: str) -> dict | None:
    """The ledger anchor signed by address: the record or one of its claims."""
    if not found.get("found"):
        return None
    for anchor in [found, *found.get("claims", [])]:
        if str(anchor.get("signer", "")).lower() == address.lower():
            return anchor
    return None


def _anchor(path: Path, record: dict, identity: Identity, pinata, gateway) -> None:
    if record.get("cid") is None:
        record["cid"] = pinata.upload(path.parent / record["file"])
        record["status"] = "uploaded_to_ipfs"
        _save(path, record)
        print(f"Uploaded {record['hash'][:16]}… to IPFS: {record['cid']}", flush=True)

    # A previous attempt may have reached the ledger before the device lost
    # power; the chaincode refuses duplicates, so look before anchoring.
    # Only the device's own anchor counts: someone else may have anchored the
    # clip first, and the ledger keeps the device's later anchor as a claim.
    existing = gateway.verify(record["hash"])
    own = _own_anchor(existing, identity.anchoring_address)
    if own is not None:
        record["status"] = DONE
        record.setdefault("blockNumber", own.get("blockNumber"))
        _save(path, record)
        return
    if existing.get("found"):
        record["anchorConflict"] = existing.get("signer")

    captured_at = int(datetime.fromisoformat(record["timestamp"]).timestamp())
    signature = cc.sign_anchor(identity.anchoring_private_key_hex, record["hash"])
    try:
        record["anchorTxId"] = gateway.anchor(record["hash"], record["cid"], captured_at, identity.node_id, signature)
    except LedgerRefused as e:
        record["status"] = REFUSED
        record["refusal"] = str(e)
        _save(path, record)
        print(f"Ledger refused {record['hash'][:16]}…: {e}", flush=True)
        return
    record["status"] = DONE
    _save(path, record)
    print(f"Anchored {record['hash'][:16]}… on Fabric, tx {record['anchorTxId']}", flush=True)


def piece_envelope(record: dict, guardian: str, identity: Identity, certificate: dict) -> dict:
    """One guardian's sealed piece, with what their phone needs to check and open the clip."""
    sealed = record["guardianShares"][guardian]
    piece_hash = hashlib.sha256(cc.unb64(sealed)).hexdigest()
    owner = certificate["ownerNodeId"]
    return {
        "manifestHash": record["hash"],
        "victimNodeId": owner,
        "fromNodeId": identity.node_id,
        "toNodeId": guardian,
        "sealedShare": sealed,
        "pieceHash": piece_hash,
        "senderX25519": cc.b64(identity.x25519_public),
        "signature": linking.sign_text(
            identity, linking.piece_payload(record["hash"], owner, identity.node_id, guardian, piece_hash)
        ),
        "certificate": certificate,
        "share": {
            "cid": record["cid"],
            "capturedAt": record["timestamp"],
            "quorum": record["threshold"],
            "signature": record["signature"],
            "source": "sos-device",
            "deviceNodeId": identity.node_id,
            "deviceEd25519": cc.b64(identity.ed25519_public),
            "deviceAnchoringAddress": identity.anchoring_address,
        },
    }


def _send_pieces(path: Path, record: dict, identity: Identity, gateway, certificate: dict) -> None:
    for guardian in _pieces_due(record, certificate):
        try:
            gateway.send_piece(piece_envelope(record, guardian, identity, certificate))
            record.setdefault("piecesSent", []).append(guardian)
            print(f"Sent guardian {guardian} their piece of {record['hash'][:16]}…", flush=True)
        except LedgerRefused as e:
            record.setdefault("piecesRefused", {})[guardian] = str(e)
            print(f"Gateway refused the piece for {guardian}: {e}", flush=True)
        _save(path, record)


def process_record(path: Path, identity: Identity, pinata, gateway, certificate: dict | None = None) -> str:
    """Moves one record as far as it can go. Returns its new status.
    Raises ServiceError when the network fails, so the caller retries later."""
    record = json.loads(path.read_text())
    if record.get("status") not in (DONE, REFUSED):
        _anchor(path, record, identity, pinata, gateway)
    if certificate is not None:
        _send_pieces(path, record, identity, gateway, certificate)
    if _can_drop_local_copy(record):
        _drop_local_copy(path, record)
    return record["status"]


def process_all(evidence_dir: Path, identity: Identity, pinata, gateway, certificate: dict | None = None) -> int:
    """One pass over the to-do list. Returns how many records are still waiting."""
    for path in pending(evidence_dir, certificate):
        try:
            process_record(path, identity, pinata, gateway, certificate)
        except ServiceError as e:
            print(f"Will retry {path.stem[:16]}…: {e}", flush=True)
            break  # no network: the rest would fail the same way
    return len(pending(evidence_dir, certificate))
