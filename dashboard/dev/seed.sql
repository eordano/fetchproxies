-- Local-preview fixtures. Designed to exercise every UI state on
-- every page so the redesign can be visually QA'd in a browser
-- without touching the live deploy.
--
-- Insert order matches FK dependencies: profiles -> runs -> snapshots
-- -> archive_results -> artifacts.
--
-- Idempotent enough: pks are explicit, ON CONFLICT skips re-runs.

-- Wipe prior seed (cascades through FKs).
TRUNCATE artifacts, archive_results, snapshots, runs RESTART IDENTITY CASCADE;
DELETE FROM nitter_mint_status;
DELETE FROM nitter_creds_override;
DELETE FROM youtube_oauth_pending;
DELETE FROM youtube_companion_status;
DELETE FROM youtube_companion_auth;

-- ---- Runs ----
INSERT INTO runs (id, tags, created_by, created_at) VALUES
    (1, '["weekly","hn"]'::jsonb,    'manual',     now() AT TIME ZONE 'UTC' - interval '6 hours'),
    (2, '["news"]'::jsonb,           'api',        now() AT TIME ZONE 'UTC' - interval '4 hours'),
    (3, '["twitter"]'::jsonb,        'rearchive',  now() AT TIME ZONE 'UTC' - interval '2 hours'),
    (4, '[]'::jsonb,                 'api',        now() AT TIME ZONE 'UTC' - interval '1 hours');
SELECT setval('runs_id_seq', (SELECT max(id) FROM runs));

-- ---- Snapshots -- one per UI state ----
-- Worker-set states get explicitly forced after archive_results inserts
-- because the recompute trigger derives state from results.
INSERT INTO snapshots (id, run_id, url, state, tags, priority, profile, created_at, updated_at) VALUES
    (1, 1, 'https://news.ycombinator.com/item?id=43821044', 'pending',
     '["weekly","hn"]'::jsonb,    0, 'full',        now() AT TIME ZONE 'UTC' - interval '5 minutes',
                                                    now() AT TIME ZONE 'UTC' - interval '5 minutes'),
    (2, 1, 'https://www.theverge.com/2026/4/30/anthropic-skills', 'running',
     '["news"]'::jsonb,           1, 'full',        now() AT TIME ZONE 'UTC' - interval '3 minutes',
                                                    now() AT TIME ZONE 'UTC' - interval '1 minute'),
    (3, 2, 'https://example.com', 'completed',
     '[]'::jsonb,                 0, 'compare',     now() AT TIME ZONE 'UTC' - interval '1 hour',
                                                    now() AT TIME ZONE 'UTC' - interval '59 minutes'),
    (4, 2, 'https://github.com/ArchiveTeam/grab-site', 'completed',
     '[]'::jsonb,                 0, 'lightweight', now() AT TIME ZONE 'UTC' - interval '90 minutes',
                                                    now() AT TIME ZONE 'UTC' - interval '88 minutes'),
    (5, 3, 'https://reddit.example.com/r/programming/top/?t=week', 'partial',
     '["reddit","weekly"]'::jsonb, 0, 'full',       now() AT TIME ZONE 'UTC' - interval '2 hours',
                                                    now() AT TIME ZONE 'UTC' - interval '2 hours'),
    (6, 4, 'https://example.com/notes/local-archive', 'failed',
     '[]'::jsonb,                 0, 'full',        now() AT TIME ZONE 'UTC' - interval '20 minutes',
                                                    now() AT TIME ZONE 'UTC' - interval '18 minutes'),
    (7, 4, 'https://wikipedia.example.com/wiki/Hypertext', 'cancelled',
     '[]'::jsonb,                 0, 'lightweight', now() AT TIME ZONE 'UTC' - interval '15 minutes',
                                                    now() AT TIME ZONE 'UTC' - interval '14 minutes'),
    -- A second completed snapshot of the same URL as #3 -- exercises
    -- the URL-history block on the snapshot detail page.
    (8, 4, 'https://example.com', 'completed',
     '[]'::jsonb,                 0, 'full',        now() AT TIME ZONE 'UTC' - interval '12 hours',
                                                    now() AT TIME ZONE 'UTC' - interval '12 hours');
SELECT setval('snapshots_id_seq', (SELECT max(id) FROM snapshots));

-- ---- Archive results ----
-- Each snapshot fans out into per-extractor rows. State per row is set
-- here directly; the recompute trigger then aligns the parent snapshot.
INSERT INTO archive_results
    (id, snapshot_id, extractor, state, priority, retry_count, max_retries, error,
     started_at, completed_at) VALUES
    -- Snapshot 1: pending (untouched queue)
    (1,  1, 'monolith',    'pending',  0, 0, 1, NULL, NULL, NULL),
    (2,  1, 'screenshot',  'pending',  0, 0, 1, NULL, NULL, NULL),
    (3,  1, 'pdf',         'pending',  0, 0, 1, NULL, NULL, NULL),
    -- Snapshot 2: running (worker mid-flight)
    (4,  2, 'monolith',    'completed', 1, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '3 minutes',
     now() AT TIME ZONE 'UTC' - interval '170 seconds'),
    (5,  2, 'screenshot',  'running',   1, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '90 seconds', NULL),
    (6,  2, 'wget_warc',   'pending',   1, 0, 1, NULL, NULL, NULL),
    -- Snapshot 3: completed (full profile)
    (7,  3, 'monolith',    'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '1 hour' + interval '2 seconds',
     now() AT TIME ZONE 'UTC' - interval '59 minutes' - interval '50 seconds'),
    (8,  3, 'pdf',         'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '1 hour' + interval '2 seconds',
     now() AT TIME ZONE 'UTC' - interval '59 minutes' - interval '40 seconds'),
    (9,  3, 'readability', 'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '1 hour' + interval '2 seconds',
     now() AT TIME ZONE 'UTC' - interval '59 minutes' - interval '55 seconds'),
    (10, 3, 'screenshot',  'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '1 hour' + interval '2 seconds',
     now() AT TIME ZONE 'UTC' - interval '59 minutes' - interval '45 seconds'),
    (11, 3, 'wget_warc',   'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '1 hour' + interval '2 seconds',
     now() AT TIME ZONE 'UTC' - interval '59 minutes' - interval '42 seconds'),
    -- Snapshot 4: completed lightweight
    (12, 4, 'monolith',    'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '90 minutes',
     now() AT TIME ZONE 'UTC' - interval '88 minutes'),
    (13, 4, 'readability', 'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '90 minutes',
     now() AT TIME ZONE 'UTC' - interval '89 minutes'),
    -- Snapshot 5: partial (one failed, others completed)
    (14, 5, 'monolith',    'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '2 hours',
     now() AT TIME ZONE 'UTC' - interval '2 hours' + interval '40 seconds'),
    (15, 5, 'screenshot',  'failed',    0, 1, 1, 'chromium timeout after 30s',
     now() AT TIME ZONE 'UTC' - interval '2 hours',
     now() AT TIME ZONE 'UTC' - interval '2 hours' + interval '30 seconds'),
    (16, 5, 'pdf',         'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '2 hours',
     now() AT TIME ZONE 'UTC' - interval '2 hours' + interval '50 seconds'),
    -- Snapshot 6: failed (all extractors failed)
    (17, 6, 'monolith',    'failed',    0, 1, 1, 'DNS resolution failed',
     now() AT TIME ZONE 'UTC' - interval '20 minutes',
     now() AT TIME ZONE 'UTC' - interval '19 minutes'),
    (18, 6, 'pdf',         'failed',    0, 1, 1, 'upstream returned 502',
     now() AT TIME ZONE 'UTC' - interval '20 minutes',
     now() AT TIME ZONE 'UTC' - interval '19 minutes'),
    -- Snapshot 7: cancelled (all skipped)
    (19, 7, 'monolith',    'skipped',   0, 0, 1, NULL, NULL, NULL),
    (20, 7, 'readability', 'skipped',   0, 0, 1, NULL, NULL, NULL),
    -- Snapshot 8: completed historical
    (21, 8, 'monolith',    'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '12 hours',
     now() AT TIME ZONE 'UTC' - interval '12 hours' + interval '30 seconds'),
    (22, 8, 'screenshot',  'completed', 0, 0, 1, NULL,
     now() AT TIME ZONE 'UTC' - interval '12 hours',
     now() AT TIME ZONE 'UTC' - interval '12 hours' + interval '40 seconds');
SELECT setval('archive_results_id_seq', (SELECT max(id) FROM archive_results));

-- ---- Artifacts (only for completed results) ----
-- Sizes feed the v2-extractor row's mono badge + the aggregate "Total".
INSERT INTO artifacts (id, result_id, snapshot_id, path, filename, content_type, size_bytes) VALUES
    -- Snapshot 2's completed monolith
    ( 1,  4, 2, 'results/2/page.html',         'page.html',         'text/html',  1_026_252),
    -- Snapshot 3 -- the "title" snapshot most pages link to
    ( 2,  7, 3, 'results/3/page.html',         'page.html',         'text/html',  1_026_252),
    ( 3,  8, 3, 'results/3/page.pdf',          'page.pdf',          'application/pdf', 2_307_891),
    ( 4,  9, 3, 'results/3/readable.html',     'readable.html',     'text/html',  3_584),
    ( 5, 10, 3, 'results/3/screenshot.png',    'screenshot.png',    'image/png',  371_712),
    ( 6, 11, 3, 'results/3/archive.warc.gz',   'archive.warc.gz',   'application/gzip', 1_363_148),
    -- Snapshot 4 lightweight
    ( 7, 12, 4, 'results/4/page.html',         'page.html',         'text/html',  892_120),
    ( 8, 13, 4, 'results/4/readable.html',     'readable.html',     'text/html',  4_096),
    -- Snapshot 5 partial
    ( 9, 14, 5, 'results/5/page.html',         'page.html',         'text/html',  1_457_664),
    (10, 16, 5, 'results/5/page.pdf',          'page.pdf',          'application/pdf', 2_097_152),
    -- Snapshot 8 historical
    (11, 21, 8, 'results/8/page.html',         'page.html',         'text/html',  978_944),
    (12, 22, 8, 'results/8/screenshot.png',    'screenshot.png',    'image/png',  364_544);
SELECT setval('artifacts_id_seq', (SELECT max(id) FROM artifacts));

-- ---- The trigger fires on result inserts but our bulk insert sets
-- state on each row directly; nudge the recompute by re-asserting the
-- snapshot states. ----
UPDATE snapshots SET state = 'pending'   WHERE id = 1;
UPDATE snapshots SET state = 'running'   WHERE id = 2;
UPDATE snapshots SET state = 'completed' WHERE id IN (3, 4, 8);
UPDATE snapshots SET state = 'partial'   WHERE id = 5;
UPDATE snapshots SET state = 'failed'    WHERE id = 6;
UPDATE snapshots SET state = 'cancelled' WHERE id = 7;

-- Extracted titles -- set for the snapshots that completed at least one
-- readability/monolith run. Mirrors what worker.sh writes on completion.
UPDATE snapshots SET extracted_title = 'Example Site -- Notes & writing' WHERE id IN (3, 8);
UPDATE snapshots SET extracted_title = 'ArchiveTeam/grab-site: Web archiving with WARC output' WHERE id = 4;

-- ---- Manual snapshot fixture ----
-- Exercises /jobs/manual on the snapshot detail page: hero shows the
-- user-provided title (winning over any auto-extracted one), the
-- "manual" pill renders next to the state pill, and the
-- "User-provided content" section lists html + markdown + a custom
-- blob with their MIME types.
INSERT INTO runs (id, tags, created_by, created_at) VALUES
    (5, '["manual","note"]'::jsonb, 'manual', now() AT TIME ZONE 'UTC' - interval '30 minutes');
SELECT setval('runs_id_seq', (SELECT max(id) FROM runs));

INSERT INTO snapshots (id, run_id, url, state, tags, priority, profile, user_provided_title, created_at, updated_at) VALUES
    (9, 5, 'https://example.com/manual-paste',
     'completed', '["manual","note"]'::jsonb, 0, 'manual',
     'Pasted notes about the May 2026 release',
     now() AT TIME ZONE 'UTC' - interval '30 minutes',
     now() AT TIME ZONE 'UTC' - interval '30 minutes');
SELECT setval('snapshots_id_seq', (SELECT max(id) FROM snapshots));

INSERT INTO snapshot_user_content (snapshot_id, key, content, mime_type, created_at) VALUES
    (9, 'html',
     '<article><h1>Pasted notes</h1><p>Sample HTML body for the manual snapshot fixture.</p></article>',
     'text/html',
     now() AT TIME ZONE 'UTC' - interval '30 minutes'),
    (9, 'markdown',
     E'# Pasted notes\n\nSample markdown body for the manual snapshot fixture.\n\n- bullet one\n- bullet two\n',
     'text/markdown',
     now() AT TIME ZONE 'UTC' - interval '30 minutes'),
    (9, 'transcript',
     E'00:00 intro\n00:14 release timeline\n01:32 known regressions\n',
     NULL,
     now() AT TIME ZONE 'UTC' - interval '30 minutes');

-- ---- Per-service egress (already seeded by schema) ----
UPDATE service_egress_mode SET reason = 'Mullvad rotation healthy', updated_at = now() AT TIME ZONE 'UTC' - interval '3 hours' WHERE service = 'nitter';

-- ---- Nitter mint status + override ----
INSERT INTO nitter_mint_status (id, last_attempt_at, last_success_at, last_source, last_env_hash, updated_at) VALUES
    (1,
     now() AT TIME ZONE 'UTC' - interval '6 hours',
     now() AT TIME ZONE 'UTC' - interval '6 hours',
     'env',
     'sha256:dummyhash',
     now() AT TIME ZONE 'UTC' - interval '6 hours');

-- ---- YouTube auth -- none (so the wizard renders) ----
-- (no insert; absence of a row is the "not signed in" state)

-- ---- YouTube companion runtime status ----
INSERT INTO youtube_companion_status (id, po_token_ready, last_attempt_at, last_success_at, effective_method, updated_at) VALUES
    (1, FALSE,
     now() AT TIME ZONE 'UTC' - interval '15 minutes',
     NULL,
     'none',
     now() AT TIME ZONE 'UTC' - interval '15 minutes');
