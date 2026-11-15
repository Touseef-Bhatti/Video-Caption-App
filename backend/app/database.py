from contextvars import ContextVar
import time

from sqlalchemy import Engine, event
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase
from app.config import get_settings

settings = get_settings()

# The request middleware installs this mutable accumulator for the duration of
# an API request. Engine events include actual SQL execution time in its scope.
server_timing_context: ContextVar[dict | None] = ContextVar("server_timing_context", default=None)


def _before_cursor_execute(conn, cursor, statement, parameters, context, executemany):
    timing = server_timing_context.get()
    if timing is not None:
        timing["query_started"][id(context)] = time.perf_counter()


def _after_cursor_execute(conn, cursor, statement, parameters, context, executemany):
    timing = server_timing_context.get()
    started = timing["query_started"].pop(id(context), None) if timing is not None else None
    if started is not None:
        timing["db_seconds"] += time.perf_counter() - started


event.listen(Engine, "before_cursor_execute", _before_cursor_execute)
event.listen(Engine, "after_cursor_execute", _after_cursor_execute)

engine = create_async_engine(settings.database_url, pool_pre_ping=True, pool_size=10, max_overflow=20)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


class Base(DeclarativeBase):
    pass


async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()
