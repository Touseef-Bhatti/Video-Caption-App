"""Persist output format and bind each export to immutable render inputs."""
from alembic import op
import sqlalchemy as sa

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("captions", sa.Column("aspect_ratio", sa.String(20), nullable=False, server_default="original"))
    op.add_column("processing_jobs", sa.Column("render_snapshot", sa.JSON(), nullable=True))
    op.add_column("exports", sa.Column("render_fingerprint", sa.String(64), nullable=True))
    op.add_column("exports", sa.Column("job_id", sa.String(36), nullable=True))


def downgrade():
    op.drop_column("exports", "job_id")
    op.drop_column("exports", "render_fingerprint")
    op.drop_column("processing_jobs", "render_snapshot")
    op.drop_column("captions", "aspect_ratio")
