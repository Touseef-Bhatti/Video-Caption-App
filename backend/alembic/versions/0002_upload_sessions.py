"""add upload_sessions table (resumable/chunked uploads)

Revision ID: 0002
Revises: 0001
Create Date: 2026-01-02 00:00:00

Added as its own migration rather than folded into 0001, in case 0001 was
already applied against a running deployment -- this keeps that upgrade
path additive instead of requiring a reset.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "upload_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=False), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=False), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("project_name", sa.String(255), nullable=False),
        sa.Column("original_filename", sa.String(500), nullable=False),
        sa.Column("mime_type", sa.String(100), nullable=False),
        sa.Column("total_size_bytes", sa.BigInteger, nullable=False),
        sa.Column("chunk_size_bytes", sa.Integer, nullable=False),
        sa.Column("total_chunks", sa.Integer, nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="uploading"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_upload_sessions_user_id", "upload_sessions", ["user_id"])
    # Speeds up the periodic cleanup sweep (workers.tasks.cleanup_expired_files),
    # which filters on status="uploading" and checks updated_at against a cutoff.
    op.create_index("ix_upload_sessions_status", "upload_sessions", ["status"])


def downgrade() -> None:
    op.drop_table("upload_sessions")
