import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.limiter import limiter
from app.security import hash_password, verify_password, create_access_token, get_current_user_id
from models.models import PasswordResetToken, User
from schemas.schemas import RegisterRequest, LoginRequest, TokenResponse

router = APIRouter(prefix="/api/auth", tags=["auth"])
logger = logging.getLogger("auth")
settings = get_settings()

RESET_TOKEN_TTL = timedelta(minutes=30)


class ForgotPasswordRequest(BaseModel):
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    token: str
    new_password: str = Field(min_length=8, max_length=128)


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _aware(dt: datetime) -> datetime:
    # SQLite (tests) returns naive datetimes; Postgres returns aware ones.
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


@router.post("/register", response_model=TokenResponse, status_code=201)
@limiter.limit(f"{settings.rate_limit_login_per_minute}/minute")
async def register(request: Request, payload: RegisterRequest, db: AsyncSession = Depends(get_db)):
    existing = await db.scalar(select(User).where(User.email == payload.email))
    if existing:
        raise HTTPException(status_code=409, detail="An account with this email already exists.")
    user = User(email=payload.email, password_hash=hash_password(payload.password))
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return TokenResponse(access_token=create_access_token(user.id))


@router.post("/login", response_model=TokenResponse)
@limiter.limit(f"{settings.rate_limit_login_per_minute}/minute")
async def login(request: Request, payload: LoginRequest, db: AsyncSession = Depends(get_db)):
    user = await db.scalar(select(User).where(User.email == payload.email))
    if not user or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Incorrect email or password.")
    return TokenResponse(access_token=create_access_token(user.id))


@router.get("/me")
async def get_me(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="Account not found.")
    return {"id": user.id, "email": user.email, "plan": user.plan, "created_at": user.created_at.isoformat()}


@router.post("/forgot-password", status_code=202)
@limiter.limit(f"{settings.rate_limit_login_per_minute}/minute")
async def forgot_password(request: Request, payload: ForgotPasswordRequest, db: AsyncSession = Depends(get_db)):
    user = await db.scalar(select(User).where(User.email == payload.email))
    # Always return the same response whether or not the email exists --
    # otherwise this endpoint leaks which emails have accounts.
    if user:
        token = secrets.token_urlsafe(32)
        db.add(PasswordResetToken(
            user_id=user.id,
            token_hash=_hash_token(token),
            expires_at=datetime.now(timezone.utc) + RESET_TOKEN_TTL,
        ))
        await db.commit()
        # No email provider is wired up yet. In development the link token is
        # logged so the flow can be tested end to end; in any other
        # environment it is NOT logged (a secret in logs is a leak), so
        # resets will not be deliverable until an email sender is added here.
        if settings.environment == "development":
            logger.info("DEV ONLY: password reset token for user_id=%s: %s", user.id, token)
        else:
            logger.warning("Password reset requested for user_id=%s but no email provider is configured.", user.id)
    return {"detail": "If an account exists for that email, a reset link is on its way."}


@router.post("/reset-password")
@limiter.limit(f"{settings.rate_limit_login_per_minute}/minute")
async def reset_password(request: Request, payload: ResetPasswordRequest, db: AsyncSession = Depends(get_db)):
    invalid = HTTPException(status_code=400, detail="This reset link is invalid or has expired.")
    record = await db.scalar(select(PasswordResetToken).where(PasswordResetToken.token_hash == _hash_token(payload.token)))
    if not record or record.used or _aware(record.expires_at) < datetime.now(timezone.utc):
        raise invalid
    user = await db.get(User, record.user_id)
    if not user:
        raise invalid
    user.password_hash = hash_password(payload.new_password)
    record.used = True  # single use
    await db.commit()
    return {"detail": "Password updated. You can now log in."}
