"""Recording with a stop button, using fake camera and mic processes."""

import signal
import subprocess
import threading
import time

import pytest

from justice_device import recorder


class FakeProc:
    """Writes its output file at once, then 'records' until its time is up or it gets SIGINT."""

    def __init__(self, out, seconds, code_on_stop=0):
        out.write_bytes(b"data")
        self.ends_at = time.monotonic() + seconds
        self.code_on_stop = code_on_stop
        self.signals = []
        self.returncode = None

    def poll(self):
        if self.returncode is None and time.monotonic() >= self.ends_at:
            self.returncode = 0
        return self.returncode

    def send_signal(self, sig):
        self.signals.append(sig)
        if self.returncode is None:
            self.returncode = self.code_on_stop

    def communicate(self, timeout=None):
        deadline = time.monotonic() + (timeout if timeout is not None else 1e9)
        while self.poll() is None:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired("fake", timeout)
            time.sleep(0.01)
        return None, ""

    def kill(self):
        self.returncode = -9


@pytest.fixture
def fakes(monkeypatch):
    procs = {}
    joined = []

    def start(cmd):
        if cmd[0] == "arecord":
            # Like the real arecord: a proper WAV, but exit code 1 after SIGINT.
            procs["mic"] = FakeProc(recorder.Path(cmd[-1]), int(cmd[cmd.index("-d") + 1]), code_on_stop=1)
            return procs["mic"]
        procs["cam"] = FakeProc(recorder.Path(cmd[-1]), int(cmd[cmd.index("-t") + 1]) / 1000)
        procs["cam_cmd"] = cmd
        return procs["cam"]

    def join(video, audio, clip):
        joined.append((video, audio))
        clip.write_bytes(b"mp4")
        return True

    monkeypatch.setattr(recorder, "_start", start)
    monkeypatch.setattr(recorder, "join", join)
    return procs, joined


def test_stop_ends_the_recording_early_and_keeps_video_and_sound(tmp_path, fakes):
    procs, joined = fakes
    stop = threading.Event()
    threading.Timer(0.3, stop.set).start()
    began = time.monotonic()
    clip = recorder.record_clip(tmp_path, "sos", 5, stop)
    assert time.monotonic() - began < 2
    assert clip == tmp_path / "sos.mp4"
    assert procs["cam"].signals == [signal.SIGINT]
    assert procs["mic"].signals == [signal.SIGINT]
    assert joined[0][1] is not None  # the sound is kept although arecord exited 1


def test_without_a_stop_it_records_the_full_length(tmp_path, fakes):
    procs, joined = fakes
    began = time.monotonic()
    clip = recorder.record_clip(tmp_path, "sos", 1, threading.Event())
    assert time.monotonic() - began >= 0.9
    assert clip is not None
    assert procs["cam"].signals == []
    assert joined[0][1] is not None


def test_records_720p_at_2_mbps(tmp_path, fakes):
    procs, _ = fakes
    recorder.record_clip(tmp_path, "sos", 1)
    cmd = procs["cam_cmd"]
    assert cmd[cmd.index("--width") + 1] == "1280"
    assert cmd[cmd.index("--height") + 1] == "720"
    assert cmd[cmd.index("--bitrate") + 1] == "2000000"
