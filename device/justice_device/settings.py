"""Who the device belongs to and who her guardians are.

Read from owner.json in the keys folder. Until linking to the phone exists
(plan phase 6), this file is written by hand or by tools/make_test_setup.py.
It holds public keys only.

    {
      "owner": {"nodeId": "...", "username": "...", "x25519Public": "<base64>"},
      "guardians": [{"nodeId": "...", "name": "...", "x25519Public": "<base64>"}],
      "allowSingleGuardian": false
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .identity import DEFAULT_KEYS_DIR

SETTINGS_FILE = "owner.json"


@dataclass(frozen=True)
class Settings:
    owner: dict | None = None
    guardians: list[dict] = field(default_factory=list)
    allow_single_guardian: bool = False

    @property
    def linked(self) -> bool:
        return self.owner is not None


def load(keys_dir: Path = DEFAULT_KEYS_DIR) -> Settings:
    path = keys_dir / SETTINGS_FILE
    if not path.exists():
        return Settings()
    data = json.loads(path.read_text())
    guardians = [g for g in data.get("guardians", []) if g.get("nodeId") and g.get("x25519Public")]
    return Settings(
        owner=data.get("owner"),
        guardians=guardians,
        allow_single_guardian=bool(data.get("allowSingleGuardian", False)),
    )
