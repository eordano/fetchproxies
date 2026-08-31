-- Fetchproxies database schema (PostgreSQL)
-- Run -> Snapshot -> ArchiveResult -> Artifact
-- Safe to re-run: every CREATE is IF NOT EXISTS / OR REPLACE.
--
-- Connection expectations (set by the Rust dashboard and worker.sh):
--   the schema is applied with `psql --single-transaction` against the
--   deployment's dedicated postgres role, reached over the microvm's
--   slirp4netns NAT (10.0.2.2:5432).
--
-- Conventions:
--   - "Enums" are CHECK constraints over TEXT.
--   - "Arrays" are JSONB columns validated via jsonb_typeof = 'array'.
--   - Timestamps are `timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')`
--     -- `timestamp without time zone`, storing UTC walltime. Rust side
--     decodes them as `chrono::NaiveDateTime`.

-- ============================================================
-- 1. Profiles -- named extractor sets
-- ============================================================
CREATE TABLE IF NOT EXISTS profiles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    extractors  JSONB NOT NULL CHECK (jsonb_typeof(extractors) = 'array'),
    created_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    updated_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

-- UPSERT keeps the seed values current across schema bumps -- INSERT-only
-- on its own would freeze whichever extractors were in `compare` etc.
-- on first init and never pick up new ones.
INSERT INTO profiles (name, extractors) VALUES
    ('full',        '["wget_warc","monolith","screenshot","screenshot_mobile","screenshot_tablet","screenshot_desktop","readability","pdf"]'),
    ('compare',     '["wget_warc","monolith","screenshot","screenshot_mobile","screenshot_tablet","screenshot_desktop","readability","pdf","bd_screenshot"]'),
    ('lightweight', '["monolith","readability"]'),
    ('warc_only',   '["wget_warc"]'),
    ('media',       '["yt_dlp"]'),
    ('screenshots', '["screenshot_mobile","screenshot_tablet","screenshot_desktop","screenshot"]'),
    ('bd_only',     '["bd_screenshot"]')
ON CONFLICT(name) DO UPDATE SET extractors = EXCLUDED.extractors;

-- ============================================================
-- 2. Runs -- a batch of snapshots submitted together
-- ============================================================
CREATE TABLE IF NOT EXISTS runs (
    id          BIGSERIAL PRIMARY KEY,
    tags        JSONB NOT NULL DEFAULT '[]'::jsonb
                  CHECK (jsonb_typeof(tags) = 'array'),
    created_by  TEXT NOT NULL DEFAULT 'api',
    created_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE INDEX IF NOT EXISTS idx_runs_created ON runs (created_at DESC);

-- ============================================================
-- 3. Snapshots -- one URL submitted once
-- ============================================================
CREATE TABLE IF NOT EXISTS snapshots (
    id            BIGSERIAL PRIMARY KEY,
    run_id        BIGINT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    url           TEXT NOT NULL,
    state         TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending','running','completed','partial','failed','cancelled')),
    tags          JSONB NOT NULL DEFAULT '[]'::jsonb
                    CHECK (jsonb_typeof(tags) = 'array'),
    priority      INTEGER NOT NULL DEFAULT 0,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    updated_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_snapshots_run_url ON snapshots (run_id, url);
CREATE INDEX IF NOT EXISTS idx_snapshots_url_created ON snapshots (url, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_snapshots_state ON snapshots (state, priority DESC, created_at);

-- The submission profile (`full`, `compare`, `lightweight`, ...) -- denormalised
-- onto the snapshot so the jobs list can render it in a single SELECT
-- instead of joining archive_results back through profiles. Defaults to
-- 'full' so historical rows survive the migration; new inserts always pass
-- the chosen profile explicitly.
ALTER TABLE snapshots ADD COLUMN IF NOT EXISTS profile TEXT NOT NULL DEFAULT 'full';

-- Page title extracted from the first readability/monolith run. Worker
-- writes once on completion (NULL -> text); subsequent runs leave it
-- alone so the original title sticks. The dashboard's hero falls back
-- to the URL when this is NULL or empty.
ALTER TABLE snapshots ADD COLUMN IF NOT EXISTS extracted_title TEXT;

-- User-supplied title for manual snapshots -- wins over the extracted
-- title when present. Manual snapshots skip the worker entirely; the
-- user posts the content directly via /jobs/manual. NULL on every
-- worker-driven snapshot.
ALTER TABLE snapshots ADD COLUMN IF NOT EXISTS user_provided_title TEXT;

-- ============================================================
-- 3b. Snapshot user content -- bodies posted by manual submissions
-- ============================================================
-- One row per (snapshot, key). Well-known keys: `html`, `markdown`.
-- Anything else is a free-form custom blob the user attached. Display
-- order is created_at ASC, so the order rows arrive in is preserved.
-- mime_type lets the dashboard pick the right preview (rendered HTML
-- iframe, monospace text, etc.); NULL falls back to a sensible default
-- inferred from the key (`html` -> text/html, `markdown` -> text/markdown,
-- everything else -> text/plain).
CREATE TABLE IF NOT EXISTS snapshot_user_content (
    id            BIGSERIAL PRIMARY KEY,
    snapshot_id   BIGINT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
    key           TEXT NOT NULL,
    content       TEXT NOT NULL,
    mime_type     TEXT,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_snapshot_user_content_snapshot_key
    ON snapshot_user_content (snapshot_id, key);
CREATE INDEX IF NOT EXISTS idx_snapshot_user_content_snapshot
    ON snapshot_user_content (snapshot_id, created_at);

-- ============================================================
-- 4. Archive results -- the work queue (one row per extractor per snapshot)
-- ============================================================
CREATE TABLE IF NOT EXISTS archive_results (
    id            BIGSERIAL PRIMARY KEY,
    snapshot_id   BIGINT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
    extractor     TEXT NOT NULL
                    CHECK (extractor IN ('wget_warc','browsertrix','yt_dlp','monolith',
                                         'screenshot','screenshot_mobile','screenshot_tablet',
                                         'screenshot_desktop',
                                         'readability','singlefile','dom_dump','pdf',
                                         'bd_screenshot')),
    state         TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending','running','completed','failed','skipped')),
    priority      INTEGER NOT NULL DEFAULT 0,
    proxy_chain   TEXT,
    -- Failures retry once. The previous default of 3 (=4 attempts incl.
    -- initial) made every broken extractor multiply its container-churn
    -- footprint 4x.
    max_retries   INTEGER NOT NULL DEFAULT 1,
    retry_count   INTEGER NOT NULL DEFAULT 0,
    error         TEXT,
    worker_id     TEXT,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    started_at    TIMESTAMP,
    completed_at  TIMESTAMP
);

-- The extractor CHECK is part of the CREATE TABLE above, but
-- CREATE TABLE IF NOT EXISTS is a no-op on existing DBs -- it never
-- updates the constraint. Drop + re-add unconditionally so adding new
-- extractors (screenshot_mobile/tablet/desktop, ...) actually takes
-- effect on long-lived databases. The constraint name follows the
-- postgres default for table-level CHECKs: `<table>_<col>_check`.
ALTER TABLE archive_results DROP CONSTRAINT IF EXISTS archive_results_extractor_check;
ALTER TABLE archive_results ADD CONSTRAINT archive_results_extractor_check
    CHECK (extractor IN ('wget_warc','browsertrix','yt_dlp','monolith',
                         'screenshot','screenshot_mobile','screenshot_tablet',
                         'screenshot_desktop',
                         'readability','singlefile','dom_dump','pdf',
                         'bd_screenshot'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_archive_results_snapshot_extractor
    ON archive_results (snapshot_id, extractor);
CREATE INDEX IF NOT EXISTS idx_archive_results_queue
    ON archive_results (priority DESC, created_at) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_archive_results_snapshot ON archive_results (snapshot_id);

-- ============================================================
-- 5. Artifacts -- files written by completed extractors
-- ============================================================
-- One row per file produced by a worker (not per result). Lets the
-- dashboard render /artifacts/results/<id>/ from this table without
-- an S3 ListObjects call. `path` is the S3 key under
-- s3://fetchproxies-artifacts/, e.g. 'results/42/screenshot.png'.

CREATE TABLE IF NOT EXISTS artifacts (
    id            BIGSERIAL PRIMARY KEY,
    result_id     BIGINT NOT NULL REFERENCES archive_results(id) ON DELETE CASCADE,
    snapshot_id   BIGINT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
    path          TEXT NOT NULL,
    filename      TEXT,
    content_type  TEXT,
    size_bytes    BIGINT,
    sha256        TEXT,
    created_at    TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE INDEX IF NOT EXISTS idx_artifacts_result ON artifacts (result_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_snapshot ON artifacts (snapshot_id);

-- ============================================================
-- 6. Snapshot state derivation triggers
-- ============================================================
-- Recompute the parent snapshot's state from its archive_results children
-- whenever a child's state changes (or a new one is inserted).
--
-- States collapse as follows (first match wins):
--   any running                                 -> running
--   any pending + any non-pending               -> running     (partially working through)
--   any pending, nothing else                   -> pending
--   any failed + any completed                  -> partial
--   any failed only                             -> failed
--   any completed (with or without skipped)     -> completed
--   any skipped only (no completed/failed)      -> cancelled
--   ELSE                                         -> completed   (defensive: no rows)

CREATE OR REPLACE FUNCTION recompute_snapshot_state(p_snapshot_id BIGINT)
RETURNS VOID AS $$
DECLARE
    new_state TEXT;
    n_running BIGINT;
    n_pending BIGINT;
    n_done    BIGINT;
    n_failed  BIGINT;
    n_completed BIGINT;
    n_skipped BIGINT;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE state = 'running'),
        COUNT(*) FILTER (WHERE state = 'pending'),
        COUNT(*) FILTER (WHERE state IN ('completed','failed','skipped')),
        COUNT(*) FILTER (WHERE state = 'failed'),
        COUNT(*) FILTER (WHERE state = 'completed'),
        COUNT(*) FILTER (WHERE state = 'skipped')
    INTO n_running, n_pending, n_done, n_failed, n_completed, n_skipped
    FROM archive_results
    WHERE snapshot_id = p_snapshot_id;

    IF n_running > 0 THEN
        new_state := 'running';
    ELSIF n_pending > 0 AND n_done > 0 THEN
        new_state := 'running';
    ELSIF n_pending > 0 THEN
        new_state := 'pending';
    ELSIF n_failed > 0 AND n_completed > 0 THEN
        new_state := 'partial';
    ELSIF n_failed > 0 THEN
        new_state := 'failed';
    ELSIF n_completed > 0 THEN
        new_state := 'completed';
    ELSIF n_skipped > 0 THEN
        new_state := 'cancelled';
    ELSE
        new_state := 'completed';
    END IF;

    UPDATE snapshots
       SET state = new_state,
           updated_at = (now() AT TIME ZONE 'UTC')
     WHERE id = p_snapshot_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_archive_results_after_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.state IS DISTINCT FROM OLD.state) THEN
        PERFORM recompute_snapshot_state(NEW.snapshot_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS archive_result_state_after_update ON archive_results;
CREATE TRIGGER archive_result_state_after_update
AFTER UPDATE OF state ON archive_results
FOR EACH ROW
EXECUTE FUNCTION trg_archive_results_after_change();

DROP TRIGGER IF EXISTS archive_result_state_after_insert ON archive_results;
CREATE TRIGGER archive_result_state_after_insert
AFTER INSERT ON archive_results
FOR EACH ROW
EXECUTE FUNCTION trg_archive_results_after_change();

-- ============================================================
-- 7. Nitter credential override + mint status
-- ============================================================
CREATE TABLE IF NOT EXISTS nitter_creds_override (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    username       TEXT,
    password       TEXT,
    totp_secret    TEXT,
    env_hash_seen  TEXT NOT NULL,
    env_decision   TEXT NOT NULL CHECK (env_decision IN ('use_env','use_override')),
    decided_at     TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'),
    updated_at     TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE TABLE IF NOT EXISTS nitter_mint_status (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    last_attempt_at TIMESTAMP,
    last_success_at TIMESTAMP,
    last_source     TEXT CHECK (last_source IN ('env','override')),
    last_env_hash   TEXT,
    last_error      TEXT,
    updated_at      TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

-- ============================================================
-- 8. Per-service egress mode
-- ============================================================
CREATE TABLE IF NOT EXISTS service_egress_mode (
    service     TEXT PRIMARY KEY
                  CHECK (service IN ('nitter','invidious','companion')),
    mode        TEXT NOT NULL DEFAULT 'proxy_chain'
                  CHECK (mode IN ('proxy_chain','direct')),
    reason      TEXT,
    updated_at  TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

INSERT INTO service_egress_mode (service, mode) VALUES
    ('nitter',    'proxy_chain'),
    ('invidious', 'proxy_chain'),
    ('companion', 'proxy_chain')
ON CONFLICT(service) DO NOTHING;

-- ============================================================
-- 9. YouTube companion auth state (OAuth + cookies override)
-- ============================================================
CREATE TABLE IF NOT EXISTS youtube_companion_auth (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    auth_method     TEXT NOT NULL DEFAULT 'none'
                      CHECK (auth_method IN ('none','oauth','cookies')),
    refresh_token   TEXT,
    access_token    TEXT,
    expires_at      TIMESTAMP,
    scope           TEXT,
    account_email   TEXT,
    cookies         TEXT,
    updated_at      TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE TABLE IF NOT EXISTS youtube_oauth_pending (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    device_code         TEXT NOT NULL,
    user_code           TEXT NOT NULL,
    verification_url    TEXT NOT NULL,
    interval_seconds    BIGINT NOT NULL DEFAULT 5,
    expires_at          TIMESTAMP NOT NULL,
    last_polled_at      TIMESTAMP,
    last_error          TEXT,
    started_at          TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);

CREATE TABLE IF NOT EXISTS youtube_companion_status (
    id                INTEGER PRIMARY KEY CHECK (id = 1),
    po_token_ready    BOOLEAN NOT NULL DEFAULT FALSE,
    last_attempt_at   TIMESTAMP,
    last_success_at   TIMESTAMP,
    last_error        TEXT,
    effective_method  TEXT CHECK (effective_method IN ('none','oauth','cookies')),
    updated_at        TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')
);
