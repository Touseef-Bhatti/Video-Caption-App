"""Create the application's Supabase/PostgreSQL schema on a fresh database.

Usage:
    Set DATABASE_URL (a PostgreSQL connection string), then run:
        python install.py

The script is idempotent for an empty/fresh-compatible database. It creates
schema only; it does not copy data from another project.
"""

import os
import sys

import psycopg2


DDL = """
CREATE TYPE jobstatus AS ENUM (
    'queued', 'uploading', 'preparing', 'extracting_audio', 'transcribing',
    'creating_captions', 'rendering', 'finalizing', 'completed', 'failed', 'cancelled'
);

CREATE TABLE users (
    id uuid PRIMARY KEY,
    email varchar(255) NOT NULL UNIQUE,
    password_hash varchar(255) NOT NULL,
    plan varchar(50) NOT NULL DEFAULT 'free',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_users_email ON users (email);

CREATE TABLE projects (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name varchar(255) NOT NULL,
    original_filename varchar(500) NOT NULL,
    duration_seconds double precision,
    status varchar(50) NOT NULL DEFAULT 'draft',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_projects_user_id ON projects (user_id);

CREATE TABLE videos (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
    storage_key varchar(1000) NOT NULL,
    mime_type varchar(100) NOT NULL,
    size_bytes bigint NOT NULL,
    duration_seconds double precision NOT NULL,
    width integer,
    height integer,
    has_audio boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE processing_jobs (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    status jobstatus NOT NULL DEFAULT 'queued',
    stage varchar(100) NOT NULL DEFAULT 'queued',
    progress integer NOT NULL DEFAULT 0,
    celery_task_id varchar(255),
    error text,
    render_snapshot json,
    render_diagnostics json,
    caption_options json,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_processing_jobs_project_id ON processing_jobs (project_id);
CREATE INDEX ix_processing_jobs_status ON processing_jobs (status);

CREATE TABLE captions (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    language varchar(100) NOT NULL,
    style_preset varchar(50) NOT NULL DEFAULT 'classic',
    caption_data json NOT NULL,
    style_overrides json,
    aspect_ratio varchar(20) NOT NULL DEFAULT 'original',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_captions_project_id ON captions (project_id);

CREATE TABLE exports (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    storage_key varchar(1000) NOT NULL,
    quality varchar(50) NOT NULL DEFAULT 'standard',
    render_fingerprint varchar(64),
    job_id varchar(36),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    output_resolution integer NOT NULL DEFAULT 0,
    output_fps integer NOT NULL DEFAULT 0
);
CREATE INDEX ix_exports_project_id ON exports (project_id);

CREATE TABLE usage (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    duration_processed_seconds double precision NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_usage_user_id ON usage (user_id);

CREATE TABLE upload_sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    project_name varchar(255) NOT NULL,
    caption_language varchar(100) NOT NULL DEFAULT 'auto',
    translate_to varchar(100),
    original_filename varchar(500) NOT NULL,
    mime_type varchar(100) NOT NULL,
    total_size_bytes bigint NOT NULL,
    chunk_size_bytes integer NOT NULL,
    total_chunks integer NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'uploading',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_upload_sessions_status ON upload_sessions (status);
CREATE INDEX ix_upload_sessions_user_id ON upload_sessions (user_id);

CREATE TABLE password_reset_tokens (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash varchar(64) NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    used boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_password_reset_tokens_token_hash ON password_reset_tokens (token_hash);
CREATE INDEX ix_password_reset_tokens_user_id ON password_reset_tokens (user_id);

CREATE TABLE alembic_version (
    version_num varchar(32) PRIMARY KEY
);

-- Match the current Supabase project: RLS is enabled on every public table.
-- The existing project has no public RLS policies; backend access uses its
-- server-side database connection.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE processing_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE captions ENABLE ROW LEVEL SECURITY;
ALTER TABLE exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE upload_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE alembic_version ENABLE ROW LEVEL SECURITY;
"""


def main() -> int:
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is not set. Provide the new database's PostgreSQL URL.", file=sys.stderr)
        return 2

    try:
        with psycopg2.connect(database_url) as connection:
            with connection.cursor() as cursor:
                cursor.execute(DDL)
        print("Database schema installed successfully.")
        return 0
    except Exception as exc:
        print(f"Database schema installation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
