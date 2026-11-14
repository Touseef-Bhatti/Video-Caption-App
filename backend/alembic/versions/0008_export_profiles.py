"""Store output resolution and frame rate for each rendered export."""
from alembic import op
import sqlalchemy as sa


revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("exports", sa.Column(
        "output_resolution", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("exports", sa.Column(
        "output_fps", sa.Integer(), nullable=False, server_default="0"))


def downgrade():
    op.drop_column("exports", "output_fps")
    op.drop_column("exports", "output_resolution")
