from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import Usage

router = APIRouter(prefix="/api/usage", tags=["usage"])


@router.get("")
async def get_usage(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    """Seconds of video transcribed, all-time and this calendar month (UTC).
    Recorded now so future paid plans can meter on it; nothing is enforced yet."""
    now = datetime.now(timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    total = await db.scalar(select(func.coalesce(func.sum(Usage.duration_processed_seconds), 0.0)).where(Usage.user_id == user_id))
    # created_at is stored as naive UTC (datetime.utcnow), so compare naively.
    month = await db.scalar(
        select(func.coalesce(func.sum(Usage.duration_processed_seconds), 0.0))
        .where(Usage.user_id == user_id, Usage.created_at >= month_start.replace(tzinfo=None))
    )
    videos = await db.scalar(select(func.count()).select_from(Usage).where(Usage.user_id == user_id))
    return {
        "total_seconds_processed": float(total or 0),
        "this_month_seconds_processed": float(month or 0),
        "videos_processed": int(videos or 0),
        "plan": "free",
    }
