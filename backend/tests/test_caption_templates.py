from services.template_catalog import (
    TEMPLATE_VERSION,
    get_template,
    list_templates,
    validate_caption_configuration,
)
from tests.test_chunked_upload_routes import client, session_factory, USER1  # noqa: F401
import uuid
from models.models import Caption, Project


def _caption(text="Hello world"):
    return {
        "language": "English",
        "segments": [{
            "start": 0.0,
            "end": 2.0,
            "text": text,
            "weight": 0.5,
            "words": [
                {"text": "Hello", "start": 0.0, "end": 0.8, "style": "normal"},
                {"text": "world", "start": 0.8, "end": 2.0, "style": "highlight"},
            ],
        }],
    }


def test_catalog_is_versioned_and_has_distinct_approved_presets():
    templates = list_templates()
    assert len(templates) >= 5
    assert len({template["id"] for template in templates}) == len(templates)
    assert {template["id"] for template in templates}.issuperset(
        {"classic", "karaoke", "minimal", "social", "simple_white", "podcast_interview"}
    )
    assert all(template["version"] == TEMPLATE_VERSION for template in templates)
    assert get_template("classic")["renderer"] == "flutter-scene"
    assert "speaker_label" in get_template("podcast_interview")["optional_elements"]
    assert get_template("unapproved") is None


def test_template_configuration_accepts_valid_multilingual_unicode_and_style():
    data = _caption("مرحبا بالعالم 🌟")
    data["language"] = "Arabic"
    data["segments"][0]["text"] = "مرحبا بالعالم 🌟"
    data["segments"][0]["words"][0]["text"] = "مرحبا"
    data["segments"][0]["words"][1]["text"] = "بالعالم"
    template, transcript, overrides = validate_caption_configuration(
        "karaoke", data, {"background_color": "#24364A", "background_opacity": 0.42}
    )
    assert template == "karaoke"
    assert transcript["language"] == "Arabic"
    assert overrides["background_opacity"] == 0.42


def test_template_configuration_rejects_unknown_template_and_unsafe_style():
    try:
        validate_caption_configuration("https://attacker.invalid/x", _caption(), {})
        assert False, "unknown template should be rejected"
    except ValueError as exc:
        assert "Unsupported" in str(exc)

    try:
        validate_caption_configuration("classic", _caption(), {"font_size": 999})
        assert False, "out of range style should be rejected"
    except ValueError as exc:
        assert "invalid" in str(exc)


def test_template_configuration_rejects_out_of_segment_word_times():
    data = _caption()
    data["segments"][0]["words"][1]["end"] = 2.5
    try:
        validate_caption_configuration("classic", data, {})
        assert False, "word outside segment should be rejected"
    except ValueError as exc:
        assert "inside" in str(exc)


async def _create_project(session_factory):
    project_id = str(uuid.uuid4())
    async with session_factory() as session:
        session.add(Project(id=project_id, user_id=USER1, name="Template API", original_filename="clip.mp4"))
        session.add(Caption(project_id=project_id, language="English", style_preset="classic",
                            caption_data=_caption(), aspect_ratio="original"))
        await session.commit()
    return project_id


async def test_template_catalog_api_and_settings_validation(client, session_factory):
    response = await client.get("/api/caption-templates")
    assert response.status_code == 200
    assert len(response.json()["templates"]) >= 5
    assert (await client.get("/api/caption-templates/karaoke")).json()["version"] == TEMPLATE_VERSION
    assert (await client.get("/api/caption-templates/not-real")).status_code == 404

    project_id = await _create_project(session_factory)
    invalid_template = await client.put(
        f"/api/projects/{project_id}/captions", json={"style_preset": "https://invalid"}
    )
    assert invalid_template.status_code == 422
    invalid_data = _caption()
    invalid_data["segments"][0]["words"][0]["end"] = 4
    invalid_timing = await client.put(
        f"/api/projects/{project_id}/captions", json={"caption_data": invalid_data}
    )
    assert invalid_timing.status_code == 422
