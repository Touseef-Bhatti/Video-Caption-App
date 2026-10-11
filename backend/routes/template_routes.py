from fastapi import APIRouter, HTTPException

from services.template_catalog import get_template, list_templates

router = APIRouter(prefix="/api/caption-templates", tags=["caption templates"])


@router.get("")
async def available_templates():
    """Return the server's approved, versioned caption template catalog."""
    return {"templates": list_templates()}


@router.get("/{template_id}")
async def template_manifest(template_id: str):
    manifest = get_template(template_id)
    if manifest is None:
        raise HTTPException(status_code=404, detail="Caption template not found.")
    return manifest
