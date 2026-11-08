"""Persist detailed server-side rendering diagnostics on processing jobs."""
from alembic import op
import sqlalchemy as sa


revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("processing_jobs", sa.Column("render_diagnostics", sa.JSON(), nullable=True))


def downgrade():
    op.drop_column("processing_jobs", "render_diagnostics")
