"""Records one SOS clip: video and sound at once, joined into one MP4.

The camera writes raw H.264, which needs no finishing off, so a recording
cut short (power cut, hung camera) is still usable. Every recorder runs with
a deadline: if it overruns it is stopped politely, then killed, and what was
recorded is kept.
"""

from __future__ import annotations

import signal
import subprocess
from pathlib import Path

MIC = "plughw:CARD=Device,DEV=0"  # the USB PnP mic, by name so a changed card number doesn't matter
FRAMERATE = 30


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


def record_clip(work_dir: Path, name: str, seconds: int) -> Path | None:
    """Records seconds of video + sound into work_dir/name.mp4. None if nothing usable was recorded."""
    work_dir.mkdir(parents=True, exist_ok=True)
    video = work_dir / f"{name}_video.h264"
    audio = work_dir / f"{name}_audio.wav"
    clip = work_dir / f"{name}.mp4"

    mic = _start(["arecord", "-D", MIC, "-d", str(seconds), "-f", "cd", "-q", str(audio)])
    cam = _start([
        "rpicam-vid", "-n", "-t", str(seconds * 1000),
        "--width", "1920", "--height", "1080", "--framerate", str(FRAMERATE),
        "--bitrate", "8000000", "--inline", "-o", str(video),
    ])
    cam_code, cam_err = _finish(cam, seconds + 15)
    mic_code, mic_err = _finish(mic, 15)

    if not video.exists() or video.stat().st_size == 0:
        print("Video failed:", cam_err[-800:], flush=True)
        return None
    if cam_code != 0:
        print("Camera warning (keeping what was recorded):", cam_err[-300:], flush=True)
    have_sound = mic_code == 0 and audio.exists() and audio.stat().st_size > 0
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
