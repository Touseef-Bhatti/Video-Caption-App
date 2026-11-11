"""Choose a usable hardware encoder; keep software exports available."""
from functools import lru_cache
import logging
import os
import subprocess

logger = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def nvenc_available() -> bool:
    # Listing encoders only proves build support. Encode a frame to also
    # verify the GPU, driver, and libnvidia-encode at runtime.
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", "color=c=black:s=320x240:d=0.1", "-frames:v", "1",
             "-c:v", "h264_nvenc", "-f", "null", "-"],
            capture_output=True, timeout=20,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def encoder_options(quality: str, preset: str, crf: str) -> tuple[str, list[str]]:
    requested = os.environ.get("CAPTION_VIDEO_ENCODER", "libx264")
    if requested not in {"auto", "libx264", "h264_nvenc"}:
        raise ValueError("CAPTION_VIDEO_ENCODER must be auto, libx264, or h264_nvenc.")
    if requested in {"auto", "h264_nvenc"}:
        if nvenc_available():
            return "h264_nvenc", ["-c:v", "h264_nvenc", "-preset",
                                  "p6" if quality == "high" else "p4",
                                  "-rc", "vbr", "-cq", str(crf), "-b:v", "0"]
        if requested == "h264_nvenc":
            raise RuntimeError("NVIDIA video encoding is unavailable on this worker.")
        logger.warning("NVENC is unavailable; rendering with libx264 on the CPU.")
    return "libx264", ["-c:v", "libx264", "-preset", preset, "-crf", str(crf)]
