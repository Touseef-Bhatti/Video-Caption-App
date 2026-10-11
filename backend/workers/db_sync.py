"""
Celery tasks run outside the FastAPI event loop, so they use a plain
synchronous SQLAlchemy session (psycopg2) against the same models/tables
the async API uses -- the ORM mapping is driver-agnostic.
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from app.config import get_settings

settings = get_settings()
sync_url = settings.database_url.replace("+asyncpg", "+psycopg2")  # explicit sync driver

sync_engine = create_engine(sync_url, pool_pre_ping=True)
SyncSessionLocal = sessionmaker(bind=sync_engine)
