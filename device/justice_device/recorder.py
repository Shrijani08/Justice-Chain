"""Records one SOS clip: video and sound at once, joined into one MP4.

The camera writes raw H.264, which needs no finishing off, so a recording
cut short (power cut, hung camera) is still usable. Every recorder runs with
a deadline: if it overruns it is stopped politely, then killed, and what was
recorded is kept. A stop asked for by the user (second button hold) ends both
recorders politely at once, and the clip so far is kept the same way.
"""

from __future__ import annotations

import signal
import subprocess
import threading
import time
from pathlib import Path

MIC = "plughw:CARD=Device,DEV=0"  # the USB PnP mic, by name so a changed card number doesn't matter
FRAMERATE = 30
# 720p at 2 Mbps: about 12 MB for 45 s instead of 45 MB at 1080p/8 Mbps, so
# uploads over a phone hotspot are about 4x faster. The OV5647 also films 720p
# from its whole sensor (1080p is a crop), so the view is wider.
WIDTH, HEIGHT = 1280, 720
BITRATE = 2_000_000


def _finish(proc: subprocess.Popen, seconds: float) -> tuple[int, str]:
    try:
        _, err = proc.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGINT)
        try:
            _, err = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            _, err = proc.communicate()
        err = (err or "") + "\n(stopped after it ran too long)"
    return proc.returncode, err or ""


def _start(cmd: list[str]) -> subprocess.Popen:
    return subprocess.Popen(
        cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True
    )


def _wait_for_stop(procs: list[subprocess.Popen], seconds: float, stop: threading.Event) -> bool:
    """True if stop was asked for while the recorders were still running."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline and any(p.poll() is None for p in procs):
        if stop.wait(timeout=0.2):
            return True
    return False


def join(video: Path, audio: Path | None, clip: Path) -> bool:
    """Wraps raw H.264 (and WAV sound, if any) into clip. Deletes the parts on success."""
    cmd = ["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-framerate", str(FRAMERATE), "-i", str(video)]
    if audio is not None:
        # No -shortest: with copied raw H.264, which has no timestamps of its
        # own, ffmpeg then drops the whole sound track without an error.
        cmd += ["-i", str(audio), "-c:v", "copy", "-c:a", "aac"]
    else:
        cmd += ["-c:v", "copy"]
    result = subprocess.run(cmd + [str(clip)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        print("Making the MP4 failed, keeping the raw files:", result.stderr[-400:], flush=True)
        return False
    video.unlink()
    if audio is not None and audio.exists():
        audio.unlink()
    return True


def record_clip(work_dir: Path, name: str, seconds: int, stop: threading.Event | None = None) -> Path | None:
    """Records up to seconds of video + sound into work_dir/name.mp4, less if stop is set.

    None if nothing usable was recorded.
    """
    work_dir.mkdir(parents=True, exist_ok=True)
    video = work_dir / f"{name}_video.h264"
    audio = work_dir / f"{name}_audio.wav"
    clip = work_dir / f"{name}.mp4"

    mic = _start(["arecord", "-D", MIC, "-d", str(seconds), "-f", "cd", "-q", str(audio)])
    cam = _start([
        "rpicam-vid", "-n", "-t", str(seconds * 1000),
        "--width", str(WIDTH), "--height", str(HEIGHT), "--framerate", str(FRAMERATE),
        "--bitrate", str(BITRATE), "--inline", "-o", str(video),
    ])
    stopped = stop is not None and _wait_for_stop([cam, mic], seconds, stop)
    if stopped:
        for proc in (cam, mic):
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)
    cam_code, cam_err = _finish(cam, seconds + 15)
    mic_code, mic_err = _finish(mic, 15)

    if not video.exists() or video.stat().st_size == 0:
        print("Video failed:", cam_err[-800:], flush=True)
        return None
    if cam_code != 0:
        print("Camera warning (keeping what was recorded):", cam_err[-300:], flush=True)
    # arecord finishes the WAV properly on SIGINT but still exits 1.
    have_sound = (mic_code == 0 or stopped) and audio.exists() and audio.stat().st_size > 0
    if not have_sound:
        print("Sound failed, keeping the video only:", mic_err[-400:], flush=True)
    return clip if join(video, audio if have_sound else None, clip) else None


def leftovers(work_dir: Path) -> list[Path]:
    """Clips left unsealed by a power cut or crash, joined into MP4s where needed."""
    if not work_dir.exists():
        return []
    for video in sorted(work_dir.glob("*_video.h264")):
        name = video.name.removesuffix("_video.h264")
        audio = work_dir / f"{name}_audio.wav"
        join(video, audio if audio.exists() and audio.stat().st_size > 0 else None, work_dir / f"{name}.mp4")
    return sorted(work_dir.glob("*.mp4"))
