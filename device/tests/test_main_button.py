"""The second button hold: stopping a recording and the LED's answer, with a fake LED."""

import threading
import time

import pytest

main = pytest.importorskip("justice_device.main")  # needs gpiozero, which the Pi has


class FakeLed:
    def __init__(self):
        self.calls = []

    def blink(self, **kwargs):
        self.calls.append(("blink", kwargs))

    def on(self):
        self.calls.append(("on", {}))


def recording_device(seconds_ago):
    device = object.__new__(main.Device)  # no real pins, keys or camera
    device.led = FakeLed()
    device.recording = True
    device.stop = threading.Event()
    device.started_at = time.monotonic() - seconds_ago
    return device


def test_a_stop_flashes_three_times_then_blinks_fast_while_locking():
    device = recording_device(10)
    device.on_hold()
    assert device.stop.is_set()
    (first, flashes), (second, fast) = device.led.calls
    assert first == "blink" and flashes["n"] == main.STOP_FLASHES and flashes["background"] is False
    assert second == "blink" and fast == {"on_time": 0.1, "off_time": 0.1}


def test_no_fast_blink_after_the_flashes_if_locking_already_finished():
    device = recording_device(10)
    device.flash_stopped = lambda: (
        setattr(device, "recording", False),  # on_sos finished meanwhile
        main.Device.flash_stopped(device),
    )
    device.on_hold()
    assert [kwargs.get("n") for _, kwargs in device.led.calls] == [main.STOP_FLASHES]


def test_a_hold_in_the_first_seconds_changes_nothing():
    device = recording_device(2)
    device.on_hold()
    assert not device.stop.is_set()
    assert device.led.calls == []


def test_a_second_stop_hold_is_ignored():
    device = recording_device(10)
    device.on_hold()
    device.led.calls.clear()
    device.on_hold()
    assert device.led.calls == []
