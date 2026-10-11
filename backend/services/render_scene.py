"""Versioned, immutable inputs shared by preview/export and download checks."""
import hashlib
import json

RENDERER_VERSION = "flutter-scene-v3"
FPS = 30


def caption_snapshot(caption, aspect_ratio=None):
    return {
        "renderer_version": RENDERER_VERSION,
        "fps": FPS,
        "caption_data": caption.caption_data,
        "style_preset": caption.style_preset,
        "style_overrides": caption.style_overrides or {},
        "aspect_ratio": aspect_ratio or caption.aspect_ratio or "original",
    }


def fingerprint(snapshot):
    return hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()
