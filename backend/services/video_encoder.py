"""Choose a usable hardware encoder; keep software exports available."""
from functools import lru_cache
import logging
import os
import subprocess

logger = logging.getLogger(__name__)


def _bitrate_bps(value: str) -> int:
    suffix = value[-1:].lower()
    amount = int(value[:-1] if suffix in {"k", "m"} else value)
    return amount * (1_000 if suffix == "k" else 1_000_000 if suffix == "m" else 1)


def _format_bitrate(bps: float) -> str:
    return f"{max(1, round(bps / 1_000))}k"


def nvenc_rate_control(source_video_bitrate_bps: int | None, output_pixels: int,
                       min_maxrate: str = "1200k", maxrate_cap: str = "2500k",
                       maxrate_override: str | None = None,
                       bufsize_override: str | None = None) -> tuple[str, str]:
    """Return NVENC VBR limits derived from source bitrate and output size."""
    if maxrate_override is not None:
        maxrate = maxrate_override
    else:
        minimum_bps = _bitrate_bps(min_maxrate)
        cap_bps = _bitrate_bps(maxrate_cap) * max(1.0, output_pixels / 921_600)
        if cap_bps < minimum_bps:
            raise ValueError("NVENC maxrate cap must be at least the minimum maxrate.")
        target_bps = cap_bps if not source_video_bitrate_bps or source_video_bitrate_bps <= 0 else 2 * source_video_bitrate_bps
        maxrate = _format_bitrate(min(cap_bps, max(minimum_bps, target_bps)))

    bufsize = bufsize_override or _format_bitrate(2 * _bitrate_bps(maxrate))
    return maxrate, bufsize


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


def encoder_options(quality: str, preset: str, crf: str, nvenc_cq: int | str | None = None,
                    source_video_bitrate_bps: int | None = None,
                    output_pixels: int = 921_600,
                    min_maxrate: str = "1200k", maxrate_cap: str = "2500k",
                    nvenc_preset: str | None = None,
                    maxrate_override: str | None = None,
                    bufsize_override: str | None = None) -> tuple[str, list[str]]:
    requested = os.environ.get("CAPTION_VIDEO_ENCODER", "libx264")
    if requested not in {"auto", "libx264", "h264_nvenc"}:
        raise ValueError("CAPTION_VIDEO_ENCODER must be auto, libx264, or h264_nvenc.")
    if requested in {"auto", "h264_nvenc"}:
        if nvenc_available():
            cq = nvenc_cq if nvenc_cq is not None else (16 if quality == "high" else 28)
            maxrate, bufsize = nvenc_rate_control(
                source_video_bitrate_bps, output_pixels, min_maxrate, maxrate_cap,
                maxrate_override, bufsize_override)
            return "h264_nvenc", [
                "-c:v", "h264_nvenc", "-preset",
                nvenc_preset or ("p6" if quality == "high" else "p4"),
                "-rc", "vbr", "-cq", str(cq), "-b:v", "0",
                "-maxrate", maxrate, "-bufsize", bufsize,
            ]
        if requested == "h264_nvenc":
            raise RuntimeError("NVIDIA video encoding is unavailable on this worker.")
        logger.warning("NVENC is unavailable; rendering with libx264 on the CPU.")
    return "libx264", ["-c:v", "libx264", "-preset", preset, "-crf", str(crf)]
