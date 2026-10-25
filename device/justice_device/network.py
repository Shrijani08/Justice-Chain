"""The device's two internet services: Pinata (IPFS) and the Fabric gateway.

Same calls as the app's pinata_service.dart and fabric_ledger_service.dart.
The keys come from config.json in the keys folder (never from the code):

    {"pinataJwt": "...", "gatewayUrl": "https://....ngrok-free.dev", "gatewayApiKey": "..."}
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import requests

from .identity import DEFAULT_KEYS_DIR

CONFIG_FILE = "config.json"
PINATA_URL = "https://api.pinata.cloud/pinning/pinFileToIPFS"
BASE_TIMEOUT = 30
MIN_BYTES_PER_SECOND = 256 * 1024  # as the app: a ~2 Mbps floor so slow uploads still finish
SUBMIT_TIMEOUT = 90  # anchoring waits for the commit on both organisations' peers
QUERY_TIMEOUT = 15


class ServiceError(Exception):
    """A failed call that is worth retrying later."""


class LedgerRefused(Exception):
    """The chaincode refused the request with its own reason; retrying won't help."""


@dataclass(frozen=True)
class Config:
    pinata_jwt: str
    gateway_url: str
    gateway_api_key: str


def load_config(keys_dir: Path = DEFAULT_KEYS_DIR) -> Config | None:
    path = keys_dir / CONFIG_FILE
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    return Config(
        pinata_jwt=data.get("pinataJwt", "").strip(),
        gateway_url=data.get("gatewayUrl", "").strip().rstrip("/"),
        gateway_api_key=data.get("gatewayApiKey", "").strip(),
    )


class Pinata:
    def __init__(self, jwt: str) -> None:
        self.jwt = jwt

    def upload(self, path: Path) -> str:
        """Uploads one file and returns its CID."""
        timeout = BASE_TIMEOUT + path.stat().st_size // MIN_BYTES_PER_SECOND
        try:
            with open(path, "rb") as f:
                response = requests.post(
                    PINATA_URL,
                    headers={"Authorization": f"Bearer {self.jwt}"},
                    files={"file": (path.name, f)},
                    timeout=timeout,
                )
        except requests.RequestException as e:
            raise ServiceError(f"No connection to Pinata: {e}") from e
        if response.status_code != 200:
            raise ServiceError(f"Pinata rejected the upload (HTTP {response.status_code})")
        cid = response.json().get("IpfsHash")
        if not cid:
            raise ServiceError("Pinata response did not include a CID")
        return cid


class Gateway:
    def __init__(self, url: str, api_key: str) -> None:
        self.url = url
        self.headers = {"X-Api-Key": api_key, "ngrok-skip-browser-warning": "1"}

    def _decode(self, response: requests.Response):
        body = response.json() if response.content else None
        if response.status_code == 200:
            return body
        message = body.get("error") if isinstance(body, dict) else None
        if response.status_code == 400:
            raise LedgerRefused(message or "bad request")
        raise ServiceError(f"Fabric gateway HTTP {response.status_code}: {message or response.text[:200]}")

    def verify(self, manifest_hash: str) -> dict:
        return self._get(f"/verify/{manifest_hash}")

    def _get(self, path: str):
        try:
            response = requests.get(f"{self.url}{path}", headers=self.headers, timeout=QUERY_TIMEOUT)
        except requests.RequestException as e:
            raise ServiceError(f"No connection to the gateway: {e}") from e
        return self._decode(response)

    def _post(self, path: str, body: dict, timeout: int = QUERY_TIMEOUT):
        try:
            response = requests.post(f"{self.url}{path}", headers=self.headers, json=body, timeout=timeout)
        except requests.RequestException as e:
            raise ServiceError(f"No connection to the gateway: {e}") from e
        return self._decode(response)

    def setup_for(self, device_node_id: str) -> dict:
        """The owner's latest setup package for this device, or {"found": False}."""
        return self._get(f"/device-setup/{device_node_id}")

    def send_piece(self, envelope: dict) -> dict:
        """Leaves one guardian's sealed key piece in their mailbox."""
        return self._post("/device-pieces", envelope)

    def anchor(self, manifest_hash: str, cid: str, captured_at: int, node_id: str, signature: str) -> str:
        """Records one clip on the ledger; returns the transaction ID."""
        body = {
            "manifestHash": manifest_hash,
            "cid": cid,
            "capturedAt": captured_at,
            "nodeId": node_id,
            "signature": signature,
        }
        return self._post("/anchor", body, SUBMIT_TIMEOUT)["txId"]
