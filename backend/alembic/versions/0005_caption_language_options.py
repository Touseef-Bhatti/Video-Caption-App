"""Store requested caption and translation languages for new uploads."""
from alembic import op
import sqlalchemy as sa


revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("processing_jobs", sa.Column("caption_options", sa.JSON(), nullable=True))
    op.add_column("upload_sessions", sa.Column(
        "caption_language", sa.String(100), nullable=False, server_default="auto"))
    op.add_column("upload_sessions", sa.Column("translate_to", sa.String(100), nullable=True))


def downgrade():
    op.drop_column("upload_sessions", "translate_to")
    op.drop_column("upload_sessions", "caption_language")
    op.drop_column("processing_jobs", "caption_options")
