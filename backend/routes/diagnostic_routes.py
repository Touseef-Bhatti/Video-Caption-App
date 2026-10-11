"""Development-only diagnostics for external service connectivity."""

import httpx
from fastapi import APIRouter, HTTPException

from app.config import get_settings

router = APIRouter(prefix="/api/diagnostics", tags=["diagnostics"])


@router.get("/gemini")
async def test_gemini() -> dict:
    settings = get_settings()
    if settings.environment != "development":
        raise HTTPException(status_code=404, detail="Not found")

    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{settings.gemini_model}:generateContent"
    )
    payload = {"contents": [{"parts": [{"text": "Reply with exactly OK"}]}]}

    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            url,
            params={"key": settings.gemini_api_key},
            json=payload,
        )

    try:
        body = response.json()
    except ValueError:
        body = {}

    error = body.get("error", {}) if isinstance(body, dict) else {}
    text = ""
    if response.is_success:
        candidates = body.get("candidates", [])
        if candidates:
            text = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")

    return {
        "ok": response.is_success,
        "http_status": response.status_code,
        "model": settings.gemini_model,
        "api_key_configured": bool(settings.gemini_api_key),
        "response_text": text,
        "error": error.get("message", "") if isinstance(error, dict) else "",
    }
