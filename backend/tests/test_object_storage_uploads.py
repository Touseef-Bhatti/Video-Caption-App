"""An upload must resume after all local container files are lost."""
import shutil

import pytest

from app.config import get_settings
from services import chunked_upload_service as chunks


@pytest.fixture
def object_chunks(tmp_path, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "temp_storage_dir", str(tmp_path / "container-a"))
    monkeypatch.setattr(settings, "chunk_storage_backend", "object_storage")
    objects = {}
    monkeypatch.setattr(chunks.storage_service, "upload_file", lambda path, key: objects.update({key: path.read_bytes()}))
    monkeypatch.setattr(chunks.storage_service, "download_file", lambda key, path: path.write_bytes(objects[key]))
    monkeypatch.setattr(chunks.storage_service, "list_keys", lambda prefix: [key for key in objects if key.startswith(prefix)])

    def delete_prefix(prefix):
        for key in list(objects):
            if key.startswith(prefix):
                del objects[key]

    monkeypatch.setattr(chunks.storage_service, "delete_prefix", delete_prefix)
    return settings, objects


def test_resume_and_assemble_in_another_container(object_chunks, tmp_path):
    settings, objects = object_chunks
    for index, data in enumerate([b"first", b"second", b"third"]):
        path = tmp_path / f"incoming-{index}"
        path.write_bytes(data)
        chunks.persist_chunk("upload-1", index, path)
        assert not path.exists()

    shutil.rmtree(settings.temp_storage_dir, ignore_errors=True)
    settings.temp_storage_dir = str(tmp_path / "container-b")
    assert chunks.received_chunk_indices("upload-1", 3) == {0, 1, 2}
    assembled = chunks.session_dir("upload-1") / "assembled.tmp"
    chunks.assemble_chunks("upload-1", 3, assembled)
    assert assembled.read_bytes() == b"firstsecondthird"
    assert len(objects) == 3
    assert not assembled.with_suffix(".download").exists()


def test_retry_and_cleanup_do_not_touch_another_upload(object_chunks, tmp_path):
    _, objects = object_chunks
    objects["upload-chunks/another/chunk_000000"] = b"keep"
    path = tmp_path / "incoming"
    for value in (b"old", b"replacement"):
        path.write_bytes(value)
        chunks.persist_chunk("upload-1", 0, path)
    assert objects["upload-chunks/upload-1/chunk_000000"] == b"replacement"
    chunks.cleanup_session("upload-1")
    assert objects == {"upload-chunks/another/chunk_000000": b"keep"}
