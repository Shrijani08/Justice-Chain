"""The SOS device program, started at power-on by systemd (sos.service).

Hold the button 1 second: record 45 s of video and sound, then lock the clip
at once (sealer). Only the locked clip and its record are kept. A background
thread then uploads it to IPFS and records it on the ledger (outbox),
retrying every 30 s while there is no network. The same thread collects the
owner's setup package from the gateway (linking), every 30 s until linked and
every 5 minutes after, so guardian changes reach the device.

Status LED (implementation plan):
  slow blink                  not linked to a phone yet (no owner.json)
  solid on                    ready, everything uploaded
  solid, short dip every 2 s  ready, clips waiting to upload
  fast blink                  recording and locking
"""

from __future__ import annotations

import threading
from datetime import datetime, timezone
from pathlib import Path
from signal import pause

from gpiozero import LED, Button

from . import linking, network, outbox, recorder, sealer, settings
from .identity import DEFAULT_KEYS_DIR, load_or_create

RECORD_SECONDS = 45
BUTTON_PIN = 17
LED_PIN = 27
WORK_DIR = Path.home() / "sos_clips" / "recording"  # plaintext exists here only until it is locked
EVIDENCE_DIR = Path.home() / "sos_evidence"  # <hash>.enc + <hash>.json
RETRY_SECONDS = 30  # while clips are waiting
IDLE_CHECK_SECONDS = 300


class Device:
    def __init__(self) -> None:
        self.identity = load_or_create(DEFAULT_KEYS_DIR)
        self.led = LED(LED_PIN)
        self.button = Button(BUTTON_PIN, hold_time=1)
        self.busy = threading.Lock()
        self.recording = False
        self.waiting = 0
        self.wake = threading.Event()

    def show_idle(self) -> None:
        if self.recording:
            return
        if not settings.load(DEFAULT_KEYS_DIR).linked:
            self.led.blink(on_time=1, off_time=1)
        elif self.waiting:
            self.led.blink(on_time=1.8, off_time=0.2)
        else:
            self.led.on()

    def lock(self, clip: Path, captured_at: datetime) -> None:
        current = settings.load(DEFAULT_KEYS_DIR)
        record = sealer.seal_clip(
            clip,
            self.identity,
            EVIDENCE_DIR,
            guardians=current.guardians,
            owner=current.owner,
            allow_single_guardian=current.allow_single_guardian,
            captured_at=captured_at,
        )
        print(
            f"Locked {record['hash'][:16]}… for {len(record['guardianShares'])} guardian(s), "
            f"threshold {record['threshold']}, owner {'yes' if 'ownerKey' in record else 'no'}",
            flush=True,
        )
        self.waiting += 1
        self.wake.set()

    def on_sos(self) -> None:
        if not self.busy.acquire(blocking=False):
            print("Already recording, ignoring the button", flush=True)
            return
        try:
            captured_at = datetime.now(timezone.utc)
            name = f"sos_{captured_at:%Y%m%d_%H%M%S}"
            print(f"SOS! Recording {RECORD_SECONDS} s of video + sound", flush=True)
            self.recording = True
            self.led.blink(on_time=0.1, off_time=0.1)
            clip = recorder.record_clip(WORK_DIR, name, RECORD_SECONDS)
            if clip is not None:
                self.lock(clip, captured_at)
        except Exception as e:
            print("SOS error:", repr(e), flush=True)
        finally:
            self.recording = False
            self.show_idle()
            self.busy.release()
            print("Ready again. Hold the button for 1 second.", flush=True)

    def lock_leftovers(self) -> None:
        """Locks clips a power cut left unlocked, so no plaintext stays on the card."""
        for clip in recorder.leftovers(WORK_DIR):
            print(f"Locking leftover clip {clip.name}", flush=True)
            try:
                self.lock(clip, datetime.fromtimestamp(clip.stat().st_mtime, timezone.utc))
            except Exception as e:
                print("Could not lock leftover clip:", repr(e), flush=True)

    def upload_loop(self) -> None:
        """Runs forever: uploads and anchors waiting clips, woken early by each new one."""
        warned = False
        while True:
            linked = linking.load_certificate(DEFAULT_KEYS_DIR) is not None
            self.wake.wait(timeout=RETRY_SECONDS if self.waiting or not linked else IDLE_CHECK_SECONDS)
            self.wake.clear()
            config = network.load_config(DEFAULT_KEYS_DIR)
            if config is None or not config.gateway_url:
                if not warned:
                    print("No config.json with gateway details: clips stay on the card", flush=True)
                    warned = True
                self.waiting = len(outbox.pending(EVIDENCE_DIR))
            else:
                gateway = network.Gateway(config.gateway_url, config.gateway_api_key)
                # One-time upload URLs from the gateway; a Pinata key only on old cards.
                pinata = network.Pinata(config.pinata_jwt) if config.pinata_jwt else network.SignedUrlPinata(gateway)
                self.check_setup(gateway)
                certificate = linking.load_certificate(DEFAULT_KEYS_DIR)
                try:
                    self.waiting = outbox.process_all(
                        EVIDENCE_DIR, self.identity, pinata, gateway, certificate
                    )
                except Exception as e:
                    print("Upload error:", repr(e), flush=True)
                    self.waiting = len(outbox.pending(EVIDENCE_DIR, certificate))
            self.show_idle()

    def check_setup(self, gateway) -> None:
        """Collects and applies a new setup package from the owner's phone, if any."""
        try:
            envelope = gateway.setup_for(self.identity.node_id)
            if not envelope.get("found"):
                return
            saved = linking.accept_setup(envelope, self.identity, DEFAULT_KEYS_DIR)
            if saved is not None:
                owner = saved["owner"]
                print(f"Linked to {owner.get('username') or owner['nodeId']}, {len(saved['guardians'])} guardian(s)", flush=True)
        except linking.SetupRejected as e:
            print("Setup package rejected:", e, flush=True)
        except network.ServiceError as e:
            print("Could not check for a setup package:", e, flush=True)

    def run(self) -> None:
        info = self.identity.public_info()
        current = settings.load(DEFAULT_KEYS_DIR)
        print(f"Device {info['nodeId']} (X25519 {info['x25519Public']})", flush=True)
        qr = linking.qr_payload(self.identity)
        (DEFAULT_KEYS_DIR / "qr.txt").write_text(qr)
        print(f"Link it from the app by scanning this QR text: {qr}", flush=True)
        if current.linked:
            print(f"Owner {current.owner.get('username') or current.owner.get('nodeId')}, "
                  f"{len(current.guardians)} guardian(s)", flush=True)
        else:
            print("Not linked to a phone yet (no owner.json): only the device can open its clips", flush=True)
        self.lock_leftovers()
        self.waiting = len(outbox.pending(EVIDENCE_DIR, linking.load_certificate(DEFAULT_KEYS_DIR)))
        self.wake.set()
        threading.Thread(target=self.upload_loop, daemon=True).start()
        self.button.when_held = self.on_sos
        self.show_idle()
        print("Ready. Hold the button for 1 second to start an SOS recording.", flush=True)
        pause()


if __name__ == "__main__":
    Device().run()
