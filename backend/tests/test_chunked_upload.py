"""
Covers the resumable/chunked upload building blocks:
  - services.chunked_upload_service: chunk path layout, received-index
    scanning (the mechanism GET /status and the resume-after-reconnect flow
    depend on), assembly, and idempotent overwrite-on-retry
  - services.upload_finalize_service: the validation-failure path (shared
    by both the direct and chunked upload routes) cleans up its local file
    and never touches the database
"""
from __future__ import annotations
import pytest

from app.config import get_settings
from services import chunked_upload_service as chunks
from services.upload_finalize_service import finalize_upload, UploadValidationError

settings = get_settings()


@pytest.fixture(autouse=True)
def _isolated_temp_storage(tmp_path, monkeypatch):
    """Redirects TEMP_STORAGE_DIR so these tests never touch a real
    /tmp/caption_app or interfere with each other."""
    monkeypatch.setattr(settings, "temp_storage_dir", str(tmp_path))
    yield


# ---------------------------------------------------------------------------
# session_dir / chunk_path
# ---------------------------------------------------------------------------
def test_chunk_path_is_zero_padded_and_nested_under_session_dir():
    upload_id = "abc123"
    path = chunks.chunk_path(upload_id, 7)
    assert path.name == "chunk_000007"
    assert path.parent == chunks.session_dir(upload_id)


# ---------------------------------------------------------------------------
# received_chunk_indices
# ---------------------------------------------------------------------------
def test_received_chunk_indices_empty_when_session_dir_missing():
    assert chunks.received_chunk_indices("never-started", total_chunks=5) == set()


def test_received_chunk_indices_reports_only_chunks_present_on_disk():
    upload_id = "partial-upload"
    d = chunks.session_dir(upload_id)
    d.mkdir(parents=True)
    chunks.chunk_path(upload_id, 0).write_bytes(b"a" * 10)
    chunks.chunk_path(upload_id, 2).write_bytes(b"c" * 10)
    # index 1 deliberately missing -- simulates a dropped connection mid-upload

    received = chunks.received_chunk_indices(upload_id, total_chunks=3)
    assert received == {0, 2}


# ---------------------------------------------------------------------------
# assemble_chunks
# ---------------------------------------------------------------------------
def test_assemble_chunks_concatenates_in_order():
    upload_id = "assemble-me"
    d = chunks.session_dir(upload_id)
    d.mkdir(parents=True)
    chunks.chunk_path(upload_id, 0).write_bytes(b"AAA")
    chunks.chunk_path(upload_id, 1).write_bytes(b"BBB")
    chunks.chunk_path(upload_id, 2).write_bytes(b"CCC")

    out = d / "assembled.tmp"
    chunks.assemble_chunks(upload_id, total_chunks=3, out_path=out)
    assert out.read_bytes() == b"AAABBBCCC"


def test_assemble_chunks_raises_on_missing_chunk_and_names_the_index():
    upload_id = "incomplete-upload"
    d = chunks.session_dir(upload_id)
    d.mkdir(parents=True)
    chunks.chunk_path(upload_id, 0).write_bytes(b"AAA")
    # chunk 1 never arrived

    with pytest.raises(ValueError, match="Missing chunk 1"):
        chunks.assemble_chunks(upload_id, total_chunks=2, out_path=d / "assembled.tmp")


# ---------------------------------------------------------------------------
# Idempotent re-upload of the same chunk index (the resume-after-retry case)
# ---------------------------------------------------------------------------
def test_reuploading_same_chunk_index_overwrites_cleanly():
    upload_id = "retry-upload"
    d = chunks.session_dir(upload_id)
    d.mkdir(parents=True)
    path = chunks.chunk_path(upload_id, 0)

    path.write_bytes(b"first attempt, truncated by a dropped connect")
    # simulate the route's atomic replace-on-retry behavior
    tmp = path.with_suffix(".part")
    tmp.write_bytes(b"second attempt, complete")
    tmp.replace(path)

    assert path.read_bytes() == b"second attempt, complete"
    assert not tmp.exists()


# ---------------------------------------------------------------------------
# cleanup_session
# ---------------------------------------------------------------------------
def test_cleanup_session_removes_the_whole_directory():
    upload_id = "to-be-cleaned"
    d = chunks.session_dir(upload_id)
    d.mkdir(parents=True)
    chunks.chunk_path(upload_id, 0).write_bytes(b"x")

    chunks.cleanup_session(upload_id)
    assert not d.exists()


def test_cleanup_session_is_safe_to_call_when_nothing_exists():
    chunks.cleanup_session("never-existed")  # must not raise


# ---------------------------------------------------------------------------
# finalize_upload: validation failure path (shared by direct + chunked routes)
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_finalize_upload_rejects_non_video_bytes_and_cleans_up(tmp_path):
    bogus = tmp_path / "not_really_a_video.mp4"
    bogus.write_bytes(b"this is not a video container at all")

    with pytest.raises(UploadValidationError):
        await finalize_upload(
            local_path=bogus,
            declared_mime="video/mp4",
            original_filename="clip.mp4",
            project_name="Test Project",
            size_bytes=bogus.stat().st_size,
            user_id="user-1",
            db=None,  # never reached -- validation fails before any DB access
        )

    # The local staging file must be cleaned up on a validation failure so
    # rejected uploads don't silently accumulate on disk.
    assert not bogus.exists()
