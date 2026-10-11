"""Auth (register/login/reset), rate limiting, and usage endpoint, against
in-memory SQLite. Proves route logic only -- not Postgres or an email provider."""
from __future__ import annotations
import hashlib
import uuid
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app.config import get_settings
from app.database import Base, get_db
from app.limiter import limiter
from app.main import app
from models.models import PasswordResetToken, Usage, User

settings = get_settings()


@pytest_asyncio.fixture
async def session_factory():
    engine = create_async_engine("sqlite+aiosqlite://", poolclass=StaticPool, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield async_sessionmaker(engine, expire_on_commit=False)
    await engine.dispose()


@pytest_asyncio.fixture
async def client(session_factory):
    async def override_db():
        async with session_factory() as s:
            yield s
    app.dependency_overrides[get_db] = override_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


async def _register(client, email="a@example.com", pw="correct-horse-1"):
    return await client.post("/api/auth/register", json={"email": email, "password": pw})


async def test_register_login_me_roundtrip(client):
    assert (await _register(client)).status_code == 201
    assert (await _register(client)).status_code == 409           # duplicate
    r = await client.post("/api/auth/login", json={"email": "a@example.com", "password": "correct-horse-1"})
    token = r.json()["access_token"]
    me = await client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.json()["email"] == "a@example.com"
    bad = await client.post("/api/auth/login", json={"email": "a@example.com", "password": "wrong"})
    assert bad.status_code == 401


async def test_protected_route_requires_token(client):
    assert (await client.get("/api/projects")).status_code == 401


async def test_password_reset_is_hashed_single_use_and_expiring(client, session_factory):
    await _register(client)
    r = await client.post("/api/auth/forgot-password", json={"email": "a@example.com"})
    unknown = await client.post("/api/auth/forgot-password", json={"email": "nobody@example.com"})
    assert r.status_code == unknown.status_code == 202
    assert r.json() == unknown.json()                              # no account enumeration

    # Only a hash is stored; craft a known token by inserting our own record.
    token = "known-test-token"
    async with session_factory() as s:
        user = await s.scalar(select(User).where(User.email == "a@example.com"))
        stored = (await s.scalars(select(PasswordResetToken))).all()
        assert len(stored) == 1 and len(stored[0].token_hash) == 64
        s.add(PasswordResetToken(user_id=user.id, token_hash=hashlib.sha256(token.encode()).hexdigest(),
                                 expires_at=datetime.now(timezone.utc) + timedelta(minutes=5)))
        s.add(PasswordResetToken(user_id=user.id, token_hash=hashlib.sha256(b"old").hexdigest(),
                                 expires_at=datetime.now(timezone.utc) - timedelta(minutes=1)))
        await s.commit()

    assert (await client.post("/api/auth/reset-password", json={"token": "old", "new_password": "newpassword1"})).status_code == 400
    assert (await client.post("/api/auth/reset-password", json={"token": token, "new_password": "short"})).status_code == 422
    ok = await client.post("/api/auth/reset-password", json={"token": token, "new_password": "newpassword1"})
    assert ok.status_code == 200
    again = await client.post("/api/auth/reset-password", json={"token": token, "new_password": "anotherpass1"})
    assert again.status_code == 400                                # single use
    login = await client.post("/api/auth/login", json={"email": "a@example.com", "password": "newpassword1"})
    assert login.status_code == 200


async def test_login_is_rate_limited(client):
    limiter.enabled = True
    limiter.reset()
    codes = []
    for _ in range(settings.rate_limit_login_per_minute + 2):
        r = await client.post("/api/auth/login", json={"email": "x@example.com", "password": "whatever1"})
        codes.append(r.status_code)
    assert codes[:settings.rate_limit_login_per_minute] == [401] * settings.rate_limit_login_per_minute
    assert codes[-1] == 429


async def test_usage_endpoint_sums_only_own_usage(client, session_factory):
    token = (await _register(client)).json()["access_token"]
    other = (await _register(client, "b@example.com")).json()["access_token"]
    async with session_factory() as s:
        me = await s.scalar(select(User).where(User.email == "a@example.com"))
        them = await s.scalar(select(User).where(User.email == "b@example.com"))
        s.add_all([Usage(user_id=me.id, duration_processed_seconds=60.0),
                   Usage(user_id=me.id, duration_processed_seconds=30.5),
                   Usage(user_id=them.id, duration_processed_seconds=999.0)])
        await s.commit()
    u = (await client.get("/api/usage", headers={"Authorization": f"Bearer {token}"})).json()
    assert u["total_seconds_processed"] == 90.5
    assert u["this_month_seconds_processed"] == 90.5
    assert u["videos_processed"] == 2
    o = (await client.get("/api/usage", headers={"Authorization": f"Bearer {other}"})).json()
    assert o["total_seconds_processed"] == 999.0
