"""Allow custom Gemini caption language names."""
from alembic import op
import sqlalchemy as sa


revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.alter_column("captions", "language", existing_type=sa.String(50), type_=sa.String(100), existing_nullable=False)


def downgrade():
    op.alter_column("captions", "language", existing_type=sa.String(100), type_=sa.String(50), existing_nullable=False)
