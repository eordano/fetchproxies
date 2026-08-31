use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::types::Json;
use sqlx::PgPool;
use std::collections::HashMap;

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Profile {
    pub id: i64,
    pub name: String,
    #[sqlx(json)]
    pub extractors: Vec<String>,
    pub created_at: NaiveDateTime,
    pub updated_at: NaiveDateTime,
}

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Snapshot {
    pub id: i64,
    pub run_id: i64,
    pub url: String,
    pub state: String,
    #[sqlx(json)]
    pub tags: Vec<String>,
    pub priority: i32,
    /// Submission profile name (e.g. `full`, `compare`). Stored
    /// denormalised on the row so the jobs list renders the profile
    /// column without joining archive_results back through profiles.
    pub profile: String,
    pub created_at: NaiveDateTime,
    pub updated_at: NaiveDateTime,
    /// First readability/monolith pass extracts <title> from the
    /// captured page and writes it here; the hero shows it instead
    /// of the URL when present.
    pub extracted_title: Option<String>,
    /// Title supplied by the user when submitting a manual snapshot.
    /// Wins over `extracted_title` when both are set; manual snapshots
    /// never run the worker, so this is the only title source for them.
    pub user_provided_title: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct SnapshotUserContent {
    pub id: i64,
    pub snapshot_id: i64,
    pub key: String,
    pub content: String,
    pub mime_type: Option<String>,
    pub created_at: NaiveDateTime,
}

impl SnapshotUserContent {
    /// MIME type to render this blob with. Falls back from the stored
    /// mime_type to a default inferred from `key` (`html` → text/html,
    /// `markdown` → text/markdown, everything else → text/plain) so the
    /// dashboard can pick a preview without extra round-trips.
    pub fn effective_mime_type(&self) -> &str {
        if let Some(m) = self.mime_type.as_deref() {
            if !m.is_empty() {
                return m;
            }
        }
        match self.key.as_str() {
            "html" => "text/html",
            "markdown" | "md" => "text/markdown",
            _ => "text/plain",
        }
    }
}

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct ArchiveResult {
    pub id: i64,
    pub snapshot_id: i64,
    pub extractor: String,
    pub state: String,
    pub priority: i32,
    pub retry_count: i32,
    pub max_retries: i32,
    pub error: Option<String>,
    pub worker_id: Option<String>,
    pub created_at: NaiveDateTime,
    pub started_at: Option<NaiveDateTime>,
    pub completed_at: Option<NaiveDateTime>,
}

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Artifact {
    pub id: i64,
    pub result_id: i64,
    pub snapshot_id: i64,
    pub path: String,
    pub filename: Option<String>,
    pub content_type: Option<String>,
    pub size_bytes: Option<i64>,
    pub sha256: Option<String>,
    pub created_at: NaiveDateTime,
}

#[derive(Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct Run {
    pub id: i64,
    #[sqlx(json)]
    pub tags: Vec<String>,
    pub created_by: String,
    pub created_at: NaiveDateTime,
}

#[derive(Debug, Serialize)]
pub struct DashboardStats {
    pub snapshots_pending: i64,
    pub snapshots_running: i64,
    pub snapshots_completed: i64,
    pub snapshots_failed: i64,
    pub total_artifacts: i64,
    pub total_size_bytes: i64,
}

#[derive(Debug, Serialize)]
pub struct BackendHealth {
    pub name: String,
    pub port: Option<u16>,
    pub status: String,
    pub http_code: Option<u16>,
    pub latency_ms: Option<i64>,
    pub checked_at: Option<String>,
}

/// Reformats an RFC3339 timestamp (`2026-04-28T20:56:14Z`) into the
/// dashboard-wide `YYYY-MM-DD HH:MM:SS` shape by dropping the `T`
/// separator and trailing `Z`. Shared by `BackendHealth` and
/// `ProxyHealth`'s `checked_at_display`.
fn format_checked_at(checked_at: &Option<String>) -> String {
    match checked_at {
        Some(s) if s.len() >= 20 && s.as_bytes()[10] == b'T' && s.ends_with('Z') => {
            let mut out = s[..s.len() - 1].to_string();
            out.replace_range(10..11, " ");
            out
        }
        Some(s) => s.clone(),
        None => "—".into(),
    }
}

impl BackendHealth {
    pub fn latency_display(&self) -> String {
        match self.latency_ms {
            Some(v) => format!("{} ms", v),
            None => "—".into(),
        }
    }
    pub fn http_code_display(&self) -> String {
        match self.http_code {
            Some(v) => v.to_string(),
            None => "—".into(),
        }
    }
    pub fn checked_at_display(&self) -> String {
        format_checked_at(&self.checked_at)
    }
    pub fn port_display(&self) -> String {
        match self.port {
            Some(v) => v.to_string(),
            None => "—".into(),
        }
    }
    /// Latency expressed as a percentage of the page-wide max — used
    /// directly as a CSS `width:` value on the latency bar so that the
    /// design's `<span class="proxy-lat__fill" style="width:Npct">`
    /// pattern can be rendered without template-side math.
    pub fn latency_pct(&self, max: i64) -> i64 {
        match self.latency_ms {
            Some(v) if max > 0 => (v * 100) / max,
            _ => 0,
        }
    }
    pub fn is_ok(&self) -> bool { self.status == "ok" }
    pub fn is_blocked(&self) -> bool { self.status == "blocked" }
    pub fn is_timeout(&self) -> bool { self.status == "timeout" }
    pub fn is_fallback(&self) -> bool { self.name == "brightdata" }
}

#[derive(Debug, Serialize)]
pub struct ProxyHealth {
    pub checked_at: Option<String>,
    pub target_url: Option<String>,
    pub backends: Vec<BackendHealth>,
}

impl ProxyHealth {
    pub fn ok_count(&self) -> usize {
        self.backends.iter().filter(|b| b.status == "ok").count()
    }
    pub fn total(&self) -> usize {
        self.backends.len()
    }
    pub fn checked_at_display(&self) -> String {
        format_checked_at(&self.checked_at)
    }
    /// Largest observed latency — feeds `latency_pct` so the latency
    /// bar widths scale to the page. Floor at 1 to avoid div-by-zero
    /// when no probe has reported a numeric value yet.
    pub fn max_latency_ms(&self) -> i64 {
        self.backends
            .iter()
            .filter_map(|b| b.latency_ms)
            .max()
            .unwrap_or(1)
            .max(1)
    }
}

pub fn parse_health(json: &str) -> ProxyHealth {
    #[derive(Deserialize)]
    struct Raw {
        #[serde(default)]
        checked_at: Option<String>,
        #[serde(default)]
        target_url: Option<String>,
        #[serde(default)]
        backends: HashMap<String, serde_json::Value>,
    }
    #[derive(Deserialize, Default)]
    struct RawBackend {
        port: Option<u16>,
        status: Option<String>,
        http_code: Option<u16>,
        latency_ms: Option<i64>,
        checked_at: Option<String>,
    }
    let raw: Raw = serde_json::from_str(json).unwrap_or_else(|_| Raw {
        checked_at: None,
        target_url: None,
        backends: HashMap::new(),
    });
    let mut backends: Vec<BackendHealth> = raw
        .backends
        .into_iter()
        .map(|(name, v)| {
            let b: RawBackend = serde_json::from_value(v).unwrap_or_default();
            BackendHealth {
                name,
                port: b.port,
                status: b.status.unwrap_or_else(|| "unknown".into()),
                http_code: b.http_code,
                latency_ms: b.latency_ms,
                checked_at: b.checked_at,
            }
        })
        .collect();
    backends.sort_by(|a, b| {
        let order = |s: &str| match s {
            "ok" => 0,
            "blocked" => 1,
            "timeout" => 2,
            _ => 3,
        };
        order(&a.status)
            .cmp(&order(&b.status))
            .then(
                a.latency_ms
                    .unwrap_or(i64::MAX)
                    .cmp(&b.latency_ms.unwrap_or(i64::MAX)),
            )
            .then(a.name.cmp(&b.name))
    });
    ProxyHealth {
        checked_at: raw.checked_at,
        target_url: raw.target_url,
        backends,
    }
}

pub async fn get_stats(pool: &PgPool) -> Result<DashboardStats, sqlx::Error> {
    let row = sqlx::query_as::<_, (i64, i64, i64, i64)>(
        "SELECT
            COALESCE(SUM(CASE WHEN state = 'pending'   THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'running'   THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'completed' THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'failed'    THEN 1 ELSE 0 END), 0)::bigint
         FROM snapshots",
    )
    .fetch_one(pool)
    .await?;

    let artifacts = sqlx::query_as::<_, (i64, i64)>(
        "SELECT COUNT(*)::bigint, COALESCE(SUM(size_bytes), 0)::bigint FROM artifacts",
    )
    .fetch_one(pool)
    .await?;

    Ok(DashboardStats {
        snapshots_pending: row.0,
        snapshots_running: row.1,
        snapshots_completed: row.2,
        snapshots_failed: row.3,
        total_artifacts: artifacts.0,
        total_size_bytes: artifacts.1,
    })
}

/// Per-state snapshot counts — drives the design's segmented-tab pills
/// (`All 11 / Queued 1 / Running 2 / Completed 6 / Partial 1 / Failed 1`).
/// Computed in one SUM/CASE pass for the same empty-table reason as
/// `get_stats`.
#[derive(Debug, Serialize, Default)]
pub struct StateCounts {
    pub all: i64,
    pub queued: i64,
    pub running: i64,
    pub completed: i64,
    pub partial: i64,
    pub failed: i64,
}

pub async fn get_state_counts(pool: &PgPool) -> Result<StateCounts, sqlx::Error> {
    let row = sqlx::query_as::<_, (i64, i64, i64, i64, i64, i64)>(
        "SELECT
            COUNT(*)::bigint,
            COALESCE(SUM(CASE WHEN state IN ('pending','queued') THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'running'   THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'completed' THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'partial'   THEN 1 ELSE 0 END), 0)::bigint,
            COALESCE(SUM(CASE WHEN state = 'failed'    THEN 1 ELSE 0 END), 0)::bigint
         FROM snapshots",
    )
    .fetch_one(pool)
    .await?;
    Ok(StateCounts {
        all: row.0,
        queued: row.1,
        running: row.2,
        completed: row.3,
        partial: row.4,
        failed: row.5,
    })
}

const SNAPSHOT_COLS: &str =
    "id, run_id, url, state, tags, priority, profile, created_at, updated_at, extracted_title, user_provided_title";

const RESET_TO_PENDING: &str = "UPDATE archive_results
            SET state = 'pending',
                retry_count = 0,
                error = NULL,
                started_at = NULL,
                completed_at = NULL,
                worker_id = NULL";

pub async fn list_snapshots(pool: &PgPool, limit: i64) -> Result<Vec<Snapshot>, sqlx::Error> {
    sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots ORDER BY created_at DESC LIMIT $1",
    ))
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub async fn list_snapshots_filtered(
    pool: &PgPool,
    state_filter: Option<&str>,
    url_filter: Option<&str>,
    tag_filter: Option<&str>,
    run_filter: Option<i64>,
    limit: i64,
) -> Result<Vec<Snapshot>, sqlx::Error> {
    let mut sql = format!("SELECT {SNAPSHOT_COLS} FROM snapshots WHERE 1=1");
    let mut idx = 0u32;
    let mut next_param = || {
        idx += 1;
        format!("${idx}")
    };
    if state_filter.is_some() {
        let p = next_param();
        sql.push_str(&format!(" AND state = {p}"));
    }
    if url_filter.is_some() {
        let p = next_param();
        sql.push_str(&format!(" AND url LIKE {p}"));
    }
    if tag_filter.is_some() {
        let p = next_param();
        sql.push_str(&format!(
            " AND jsonb_path_exists(tags, ('$[*] ? (@ == \"' || {p} || '\")')::jsonpath)"
        ));
    }
    if run_filter.is_some() {
        let p = next_param();
        sql.push_str(&format!(" AND run_id = {p}"));
    }
    let limit_p = next_param();
    sql.push_str(&format!(
        " ORDER BY priority DESC, created_at DESC LIMIT {limit_p}"
    ));

    let mut q = sqlx::query_as::<_, Snapshot>(&sql);
    if let Some(s) = state_filter {
        q = q.bind(s.to_string());
    }
    if let Some(u) = url_filter {
        q = q.bind(format!("%{}%", u));
    }
    if let Some(t) = tag_filter {
        q = q.bind(t.to_string());
    }
    if let Some(r) = run_filter {
        q = q.bind(r);
    }
    q.bind(limit).fetch_all(pool).await
}

pub async fn get_snapshot(pool: &PgPool, id: i64) -> Result<Option<Snapshot>, sqlx::Error> {
    sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots WHERE id = $1",
    ))
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub async fn list_url_history(
    pool: &PgPool,
    url: &str,
    exclude_id: i64,
    limit: i64,
) -> Result<Vec<Snapshot>, sqlx::Error> {
    sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots
          WHERE url = $1 AND id != $2
          ORDER BY created_at DESC LIMIT $3",
    ))
    .bind(url)
    .bind(exclude_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub async fn get_snapshot_results(
    pool: &PgPool,
    snapshot_id: i64,
) -> Result<Vec<ArchiveResult>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveResult>(
        "SELECT id, snapshot_id, extractor, state, priority, retry_count, max_retries,
                error, worker_id, created_at, started_at, completed_at
         FROM archive_results WHERE snapshot_id = $1 ORDER BY extractor",
    )
    .bind(snapshot_id)
    .fetch_all(pool)
    .await
}

/// Variant used by the snapshot-detail UI: joins artifact size in via
/// the result_id FK so the merged extractor-results-and-artifacts table
/// can render `extractor (size)` + `download` button without a second
/// per-row query.
#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct ResultRow {
    pub id: i64,
    pub snapshot_id: i64,
    pub extractor: String,
    pub state: String,
    pub retry_count: i32,
    pub max_retries: i32,
    pub error: Option<String>,
    pub started_at: Option<NaiveDateTime>,
    pub completed_at: Option<NaiveDateTime>,
    pub size_bytes: Option<i64>,
}

impl ResultRow {
    pub fn size_display(&self) -> String {
        match self.size_bytes {
            None => "—".into(),
            Some(b) if b < 1024 => format!("{} B", b),
            Some(b) if b < 1024 * 1024 => format!("{:.1} KB", b as f64 / 1024.0),
            Some(b) if b < 1024 * 1024 * 1024 => format!("{:.1} MB", b as f64 / 1048576.0),
            Some(b) => format!("{:.2} GB", b as f64 / 1073741824.0),
        }
    }
    pub fn when_display(&self) -> String {
        if let Some(t) = self.completed_at {
            t.format("%Y-%m-%d %H:%M:%S").to_string()
        } else if let Some(t) = self.started_at {
            t.format("%Y-%m-%d %H:%M:%S").to_string()
        } else {
            "—".into()
        }
    }
    pub fn is_completed(&self) -> bool {
        self.state == "completed"
    }
    pub fn can_retry(&self) -> bool {
        self.state == "failed" || self.state == "skipped"
    }
    pub fn has_retried(&self) -> bool {
        self.retry_count > 0
    }
    /// Path of the icon partial under templates/fragments/icons/ that
    /// matches this extractor. Mirrors design/app-shell.jsx's
    /// SNAPSHOT.extractors mapping (FileArchive / FileText / Book /
    /// Camera / FileImage) so the v2-extractor row renders the same
    /// glyph the design canvas does.
    pub fn extractor_icon(&self) -> &'static str {
        match self.extractor.as_str() {
            "monolith" | "wget_warc" | "singlefile" | "browsertrix" => "file_archive",
            "pdf" | "dom_dump" => "file_text",
            "screenshot"
            | "bd_screenshot"
            | "screenshot_mobile"
            | "screenshot_tablet"
            | "screenshot_desktop" => "camera",
            "readability" => "book",
            "yt_dlp" => "file_image",
            _ => "file",
        }
    }
    /// One-line plain-English description of what this extractor
    /// produces — drives the muted text next to the extractor name in
    /// the v2-extractor row.
    pub fn extractor_desc(&self) -> &'static str {
        match self.extractor.as_str() {
            "monolith" => "Single-file HTML",
            "wget_warc" => "WARC bundle",
            "screenshot" => "Full-page PNG · 1920w",
            "screenshot_mobile" => "Full-page PNG · 390w (mobile)",
            "screenshot_tablet" => "Full-page PNG · 820w (tablet)",
            "screenshot_desktop" => "Full-page PNG · 1440w (desktop)",
            "bd_screenshot" => "Bright-data full-page PNG · 1920w",
            "pdf" => "Print-to-PDF",
            "dom_dump" => "JS-rendered DOM",
            "singlefile" => "Self-contained HTML",
            "readability" => "Article body, plain",
            "yt_dlp" => "Video / audio",
            "browsertrix" => "WACZ bundle",
            _ => "",
        }
    }
}

pub async fn get_snapshot_result_rows(
    pool: &PgPool,
    snapshot_id: i64,
) -> Result<Vec<ResultRow>, sqlx::Error> {
    sqlx::query_as::<_, ResultRow>(
        "SELECT ar.id, ar.snapshot_id, ar.extractor, ar.state, ar.retry_count,
                ar.max_retries, ar.error, ar.started_at, ar.completed_at,
                a.size_bytes
         FROM archive_results ar
    LEFT JOIN artifacts a ON a.result_id = ar.id
         WHERE ar.snapshot_id = $1
      ORDER BY ar.extractor",
    )
    .bind(snapshot_id)
    .fetch_all(pool)
    .await
}

pub async fn get_snapshot_artifacts(
    pool: &PgPool,
    snapshot_id: i64,
) -> Result<Vec<Artifact>, sqlx::Error> {
    sqlx::query_as::<_, Artifact>(
        "SELECT id, result_id, snapshot_id, path, filename, content_type, size_bytes, sha256, created_at
         FROM artifacts WHERE snapshot_id = $1 ORDER BY created_at",
    )
    .bind(snapshot_id)
    .fetch_all(pool)
    .await
}

pub async fn list_runs(pool: &PgPool, limit: i64) -> Result<Vec<Run>, sqlx::Error> {
    sqlx::query_as::<_, Run>(
        "SELECT id, tags, created_by, created_at
         FROM runs ORDER BY created_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub async fn get_run(pool: &PgPool, id: i64) -> Result<Option<Run>, sqlx::Error> {
    sqlx::query_as::<_, Run>(
        "SELECT id, tags, created_by, created_at FROM runs WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub async fn list_run_snapshots(
    pool: &PgPool,
    run_id: i64,
) -> Result<Vec<Snapshot>, sqlx::Error> {
    sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots WHERE run_id = $1
          ORDER BY priority DESC, created_at",
    ))
    .bind(run_id)
    .fetch_all(pool)
    .await
}

/// Create a run + N snapshots in one transaction. Each snapshot fans out
/// into one archive_result per extractor in `profile`. Tag list is shared
/// by the run and every snapshot inside it. Returns (run_id, snapshot_ids).
///
/// Duplicate URLs within `urls` are silently deduped by the
/// idx_snapshots_run_url unique index (ON CONFLICT DO NOTHING).
pub async fn create_run_with_snapshots(
    pool: &PgPool,
    urls: &[String],
    profile: &str,
    priority: i32,
    tags: &[String],
    proxy_chain_override: Option<&str>,
    created_by: &str,
) -> Result<(i64, Vec<i64>), sqlx::Error> {
    let tags_value = serde_json::to_value(tags).unwrap_or(serde_json::Value::Array(vec![]));
    let proxy_chain = proxy_chain_override.filter(|s| !s.is_empty());

    let mut tx = pool.begin().await?;

    let prof = sqlx::query_as::<_, (i64, Json<Vec<String>>)>(
        "SELECT id, extractors FROM profiles WHERE name = $1",
    )
    .bind(profile)
    .fetch_optional(&mut *tx)
    .await?;
    let (_profile_id, extractors_json) = match prof {
        Some(p) => p,
        None => return Err(sqlx::Error::RowNotFound),
    };
    let extractors: Vec<String> = extractors_json.0;
    if extractors.is_empty() || extractors.iter().any(|e| e.is_empty()) {
        return Err(sqlx::Error::Protocol(format!(
            "profile '{}' has empty or invalid extractors: {:?}",
            profile, extractors
        )));
    }

    let (run_id,): (i64,) = sqlx::query_as(
        "INSERT INTO runs (tags, created_by) VALUES ($1, $2) RETURNING id",
    )
    .bind(&tags_value)
    .bind(created_by)
    .fetch_one(&mut *tx)
    .await?;

    let mut snapshot_ids = Vec::with_capacity(urls.len());
    for url in urls {
        if url.is_empty() {
            continue;
        }
        sqlx::query(
            "INSERT INTO snapshots (run_id, url, tags, priority, profile)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (run_id, url) DO NOTHING",
        )
        .bind(run_id)
        .bind(url)
        .bind(&tags_value)
        .bind(priority)
        .bind(profile)
        .execute(&mut *tx)
        .await?;
        let snapshot_id: i64 =
            sqlx::query_scalar("SELECT id FROM snapshots WHERE run_id = $1 AND url = $2")
                .bind(run_id)
                .bind(url)
                .fetch_one(&mut *tx)
                .await?;
        let existing: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)::bigint FROM archive_results WHERE snapshot_id = $1",
        )
        .bind(snapshot_id)
        .fetch_one(&mut *tx)
        .await?;
        if existing == 0 {
            for extractor in &extractors {
                sqlx::query(
                    "INSERT INTO archive_results (snapshot_id, extractor, priority, proxy_chain)
                     VALUES ($1, $2, $3, $4)",
                )
                .bind(snapshot_id)
                .bind(extractor)
                .bind(priority)
                .bind(proxy_chain)
                .execute(&mut *tx)
                .await?;
            }
        }
        snapshot_ids.push(snapshot_id);
    }

    tx.commit().await?;
    Ok((run_id, snapshot_ids))
}

/// One (key, content, mime_type?) blob attached to a manual snapshot.
/// `mime_type` is optional — the storage layer trusts the caller, but
/// the dashboard's read path falls back to a key-driven default if it's
/// missing (see `SnapshotUserContent::effective_mime_type`).
#[derive(Debug, Clone, Deserialize)]
pub struct ManualContent {
    pub key: String,
    pub content: String,
    pub mime_type: Option<String>,
}

/// Create a single manual snapshot — no worker fan-out, no extractor
/// rows. State is forced to `completed` so the URL-history block on the
/// detail page shows it as a finished archive of the URL. The caller's
/// `title` becomes `user_provided_title` (precedence over extracted);
/// each `(key, content, mime_type)` triple turns into a row in
/// `snapshot_user_content`. Returns (run_id, snapshot_id).
///
/// The `profile` column is set to a sentinel (`'manual'`) so the jobs
/// list can filter manual submissions out without joining additional
/// tables — the existing CHECK constraint is text-only, no allowlist,
/// so the value passes through.
pub async fn create_manual_snapshot(
    pool: &PgPool,
    url: &str,
    title: Option<&str>,
    contents: &[ManualContent],
    tags: &[String],
    priority: i32,
    created_by: &str,
) -> Result<(i64, i64), sqlx::Error> {
    let tags_value = serde_json::to_value(tags).unwrap_or(serde_json::Value::Array(vec![]));

    let mut tx = pool.begin().await?;

    let (run_id,): (i64,) = sqlx::query_as(
        "INSERT INTO runs (tags, created_by) VALUES ($1, $2) RETURNING id",
    )
    .bind(&tags_value)
    .bind(created_by)
    .fetch_one(&mut *tx)
    .await?;

    let title_owned: Option<String> = title.map(|s| s.to_string()).filter(|s| !s.is_empty());
    let snapshot_id: i64 = sqlx::query_scalar(
        "INSERT INTO snapshots
            (run_id, url, state, tags, priority, profile, user_provided_title)
         VALUES ($1, $2, 'completed', $3, $4, 'manual', $5)
         RETURNING id",
    )
    .bind(run_id)
    .bind(url)
    .bind(&tags_value)
    .bind(priority)
    .bind(&title_owned)
    .fetch_one(&mut *tx)
    .await?;

    for c in contents {
        if c.key.is_empty() || c.content.is_empty() {
            continue;
        }
        let mime: Option<String> = c
            .mime_type
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
        sqlx::query(
            "INSERT INTO snapshot_user_content (snapshot_id, key, content, mime_type)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (snapshot_id, key) DO UPDATE
                SET content = EXCLUDED.content,
                    mime_type = EXCLUDED.mime_type",
        )
        .bind(snapshot_id)
        .bind(&c.key)
        .bind(&c.content)
        .bind(&mime)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok((run_id, snapshot_id))
}

/// Read all user-content blobs attached to a snapshot, oldest first.
pub async fn get_snapshot_user_content(
    pool: &PgPool,
    snapshot_id: i64,
) -> Result<Vec<SnapshotUserContent>, sqlx::Error> {
    sqlx::query_as::<_, SnapshotUserContent>(
        "SELECT id, snapshot_id, key, content, mime_type, created_at
           FROM snapshot_user_content
          WHERE snapshot_id = $1
          ORDER BY created_at ASC, id ASC",
    )
    .bind(snapshot_id)
    .fetch_all(pool)
    .await
}

/// Re-archive an existing snapshot: copy its url + tags + per-row
/// proxy_chain into a brand-new single-snapshot run.
pub async fn rearchive_snapshot(
    pool: &PgPool,
    snapshot_id: i64,
    profile_override: Option<&str>,
) -> Result<i64, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let original = sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots WHERE id = $1",
    ))
    .bind(snapshot_id)
    .fetch_one(&mut *tx)
    .await?;

    let rows: Vec<(String, Option<String>)> = sqlx::query_as(
        "SELECT extractor, proxy_chain FROM archive_results
          WHERE snapshot_id = $1 ORDER BY id",
    )
    .bind(snapshot_id)
    .fetch_all(&mut *tx)
    .await?;
    let chain_by_extractor: std::collections::HashMap<String, Option<String>> =
        rows.iter().cloned().collect();

    let extractors: Vec<String> = if let Some(profile) = profile_override {
        let prof = sqlx::query_as::<_, (Json<Vec<String>>,)>(
            "SELECT extractors FROM profiles WHERE name = $1",
        )
        .bind(profile)
        .fetch_optional(&mut *tx)
        .await?;
        match prof {
            Some((j,)) => j.0,
            None => return Err(sqlx::Error::RowNotFound),
        }
    } else {
        let mut seen = std::collections::HashSet::new();
        rows.iter()
            .map(|(e, _)| e.clone())
            .filter(|e| seen.insert(e.clone()))
            .collect()
    };

    if extractors.is_empty() {
        return Err(sqlx::Error::Protocol(format!(
            "snapshot {} yields no extractors (no archive_results, or profile lookup empty)",
            snapshot_id
        )));
    }

    let new_tags: Vec<String> = original
        .tags
        .iter()
        .filter(|t| !t.starts_with("batch-"))
        .cloned()
        .collect();
    let tags_value = serde_json::to_value(&new_tags).unwrap_or(serde_json::Value::Array(vec![]));

    let (run_id,): (i64,) = sqlx::query_as(
        "INSERT INTO runs (tags, created_by) VALUES ($1, 'rearchive') RETURNING id",
    )
    .bind(&tags_value)
    .fetch_one(&mut *tx)
    .await?;

    let new_profile = profile_override
        .map(|s| s.to_string())
        .unwrap_or_else(|| original.profile.clone());

    let (new_snapshot_id,): (i64,) = sqlx::query_as(
        "INSERT INTO snapshots (run_id, url, tags, priority, profile)
         VALUES ($1, $2, $3, $4, $5) RETURNING id",
    )
    .bind(run_id)
    .bind(&original.url)
    .bind(&tags_value)
    .bind(original.priority)
    .bind(&new_profile)
    .fetch_one(&mut *tx)
    .await?;

    for extractor in &extractors {
        let chain = chain_by_extractor
            .get(extractor)
            .and_then(|c| c.clone());
        sqlx::query(
            "INSERT INTO archive_results (snapshot_id, extractor, priority, proxy_chain)
             VALUES ($1, $2, $3, $4)",
        )
        .bind(new_snapshot_id)
        .bind(extractor)
        .bind(original.priority)
        .bind(chain)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(new_snapshot_id)
}

pub async fn retry_snapshot(pool: &PgPool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query(&format!(
        "{RESET_TO_PENDING}
          WHERE snapshot_id = $1 AND state IN ('failed','skipped')",
    ))
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn retry_result(pool: &PgPool, result_id: i64) -> Result<(), sqlx::Error> {
    sqlx::query(&format!("{RESET_TO_PENDING} WHERE id = $1"))
        .bind(result_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn cancel_snapshot(pool: &PgPool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE archive_results
            SET state = 'skipped'
          WHERE snapshot_id = $1 AND state IN ('pending','running')",
    )
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn delete_snapshot(pool: &PgPool, id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM snapshots WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn retry_run(pool: &PgPool, run_id: i64) -> Result<(), sqlx::Error> {
    sqlx::query(&format!(
        "{RESET_TO_PENDING}
          WHERE snapshot_id IN (SELECT id FROM snapshots WHERE run_id = $1)
            AND state IN ('failed','skipped')",
    ))
    .bind(run_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn cancel_run(pool: &PgPool, run_id: i64) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE archive_results
            SET state = 'skipped'
          WHERE snapshot_id IN (SELECT id FROM snapshots WHERE run_id = $1)
            AND state IN ('pending','running')",
    )
    .bind(run_id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn delete_run(pool: &PgPool, run_id: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM runs WHERE id = $1")
        .bind(run_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn list_profiles(pool: &PgPool) -> Result<Vec<Profile>, sqlx::Error> {
    sqlx::query_as::<_, Profile>(
        "SELECT id, name, extractors, created_at, updated_at
         FROM profiles ORDER BY name",
    )
    .fetch_all(pool)
    .await
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct NitterMintStatus {
    pub last_attempt_at: Option<NaiveDateTime>,
    pub last_success_at: Option<NaiveDateTime>,
    pub last_source: Option<String>,
    pub last_env_hash: Option<String>,
    pub last_error: Option<String>,
    pub updated_at: NaiveDateTime,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct NitterCredsOverride {
    pub username: Option<String>,
    pub password: Option<String>,
    pub totp_secret: Option<String>,
    pub env_hash_seen: String,
    pub env_decision: String,
    pub decided_at: NaiveDateTime,
    pub updated_at: NaiveDateTime,
}

pub async fn get_nitter_mint_status(
    pool: &PgPool,
) -> Result<Option<NitterMintStatus>, sqlx::Error> {
    sqlx::query_as::<_, NitterMintStatus>(
        "SELECT last_attempt_at, last_success_at, last_source, last_env_hash, last_error, updated_at
         FROM nitter_mint_status WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
}

pub async fn get_nitter_creds_override(
    pool: &PgPool,
) -> Result<Option<NitterCredsOverride>, sqlx::Error> {
    sqlx::query_as::<_, NitterCredsOverride>(
        "SELECT username, password, totp_secret, env_hash_seen, env_decision, decided_at, updated_at
         FROM nitter_creds_override WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
}

pub async fn upsert_nitter_override(
    pool: &PgPool,
    username: &str,
    password: &str,
    totp_secret: &str,
    env_decision: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO nitter_creds_override
           (id, username, password, totp_secret, env_hash_seen, env_decision)
         VALUES (1, $1, $2, $3, '', $4)
         ON CONFLICT (id) DO UPDATE SET
           username     = EXCLUDED.username,
           password     = EXCLUDED.password,
           totp_secret  = EXCLUDED.totp_secret,
           env_decision = EXCLUDED.env_decision,
           updated_at   = (now() AT TIME ZONE 'UTC')",
    )
    .bind(username)
    .bind(password)
    .bind(totp_secret)
    .bind(env_decision)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn clear_nitter_override(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM nitter_creds_override WHERE id = 1")
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(Debug, Serialize, sqlx::FromRow, Clone)]
pub struct ServiceEgressMode {
    pub service: String,
    pub mode: String,
    pub reason: Option<String>,
    pub updated_at: NaiveDateTime,
}

pub async fn get_egress_mode(
    pool: &PgPool,
    service: &str,
) -> Result<Option<ServiceEgressMode>, sqlx::Error> {
    sqlx::query_as::<_, ServiceEgressMode>(
        "SELECT service, mode, reason, updated_at
         FROM service_egress_mode WHERE service = $1",
    )
    .bind(service)
    .fetch_optional(pool)
    .await
}

pub async fn set_egress_mode(
    pool: &PgPool,
    service: &str,
    mode: &str,
    reason: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO service_egress_mode (service, mode, reason)
         VALUES ($1, $2, $3)
         ON CONFLICT(service) DO UPDATE SET
            mode       = EXCLUDED.mode,
            reason     = EXCLUDED.reason,
            updated_at = (now() AT TIME ZONE 'UTC')",
    )
    .bind(service)
    .bind(mode)
    .bind(reason)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct YoutubeCompanionAuth {
    pub auth_method: String,
    pub refresh_token: Option<String>,
    pub access_token: Option<String>,
    pub expires_at: Option<NaiveDateTime>,
    pub scope: Option<String>,
    pub account_email: Option<String>,
    pub cookies: Option<String>,
    pub updated_at: NaiveDateTime,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct YoutubeOauthPending {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub interval_seconds: i64,
    pub expires_at: NaiveDateTime,
    pub last_polled_at: Option<NaiveDateTime>,
    pub last_error: Option<String>,
    pub started_at: NaiveDateTime,
}

impl YoutubeOauthPending {
    /// Whole minutes until the device code expires, floored at 0.
    pub fn minutes_until_expiry(&self) -> i64 {
        let secs = (self.expires_at - chrono::Utc::now().naive_utc()).num_seconds();
        if secs <= 0 { 0 } else { (secs + 59) / 60 }
    }
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct YoutubeCompanionStatus {
    pub po_token_ready: bool,
    pub last_attempt_at: Option<NaiveDateTime>,
    pub last_success_at: Option<NaiveDateTime>,
    pub last_error: Option<String>,
    pub effective_method: Option<String>,
    pub updated_at: NaiveDateTime,
}

pub async fn get_youtube_auth(
    pool: &PgPool,
) -> Result<Option<YoutubeCompanionAuth>, sqlx::Error> {
    sqlx::query_as::<_, YoutubeCompanionAuth>(
        "SELECT auth_method, refresh_token, access_token, expires_at, scope,
                account_email, cookies, updated_at
         FROM youtube_companion_auth WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
}

pub async fn get_youtube_oauth_pending(
    pool: &PgPool,
) -> Result<Option<YoutubeOauthPending>, sqlx::Error> {
    sqlx::query_as::<_, YoutubeOauthPending>(
        "SELECT device_code, user_code, verification_url, interval_seconds,
                expires_at, last_polled_at, last_error, started_at
         FROM youtube_oauth_pending WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
}

pub async fn get_youtube_companion_status(
    pool: &PgPool,
) -> Result<Option<YoutubeCompanionStatus>, sqlx::Error> {
    sqlx::query_as::<_, YoutubeCompanionStatus>(
        "SELECT po_token_ready, last_attempt_at, last_success_at, last_error,
                effective_method, updated_at
         FROM youtube_companion_status WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
}

pub async fn upsert_youtube_cookies(
    pool: &PgPool,
    cookies: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO youtube_companion_auth (id, auth_method, cookies)
         VALUES (1, 'cookies', $1)
         ON CONFLICT(id) DO UPDATE SET
            auth_method   = 'cookies',
            cookies       = EXCLUDED.cookies,
            updated_at    = (now() AT TIME ZONE 'UTC')",
    )
    .bind(cookies)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn upsert_youtube_oauth_token(
    pool: &PgPool,
    refresh_token: &str,
    access_token: Option<&str>,
    expires_at: Option<NaiveDateTime>,
    scope: Option<&str>,
    account_email: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO youtube_companion_auth
            (id, auth_method, refresh_token, access_token, expires_at,
             scope, account_email)
         VALUES (1, 'oauth', $1, $2, $3, $4, $5)
         ON CONFLICT(id) DO UPDATE SET
            auth_method   = 'oauth',
            refresh_token = EXCLUDED.refresh_token,
            access_token  = EXCLUDED.access_token,
            expires_at    = EXCLUDED.expires_at,
            scope         = EXCLUDED.scope,
            account_email = EXCLUDED.account_email,
            updated_at    = (now() AT TIME ZONE 'UTC')",
    )
    .bind(refresh_token)
    .bind(access_token)
    .bind(expires_at)
    .bind(scope)
    .bind(account_email)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn clear_youtube_auth(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO youtube_companion_auth (id, auth_method)
         VALUES (1, 'none')
         ON CONFLICT(id) DO UPDATE SET
            auth_method   = 'none',
            refresh_token = NULL,
            access_token  = NULL,
            expires_at    = NULL,
            scope         = NULL,
            account_email = NULL,
            cookies       = NULL,
            updated_at    = (now() AT TIME ZONE 'UTC')",
    )
    .execute(pool)
    .await?;
    sqlx::query("DELETE FROM youtube_oauth_pending WHERE id = 1")
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExportData {
    pub runs: Vec<Run>,
    pub snapshots: Vec<Snapshot>,
    pub archive_results: Vec<ArchiveResult>,
    pub artifacts: Vec<Artifact>,
}

pub async fn export_all(pool: &PgPool) -> Result<ExportData, sqlx::Error> {
    let runs = sqlx::query_as::<_, Run>(
        "SELECT id, tags, created_by, created_at FROM runs ORDER BY id",
    )
    .fetch_all(pool)
    .await?;

    let snapshots = sqlx::query_as::<_, Snapshot>(&format!(
        "SELECT {SNAPSHOT_COLS} FROM snapshots ORDER BY id",
    ))
    .fetch_all(pool)
    .await?;

    let archive_results = sqlx::query_as::<_, ArchiveResult>(
        "SELECT id, snapshot_id, extractor, state, priority, retry_count, max_retries,
                error, worker_id, created_at, started_at, completed_at
         FROM archive_results ORDER BY id",
    )
    .fetch_all(pool)
    .await?;

    let artifacts = sqlx::query_as::<_, Artifact>(
        "SELECT id, result_id, snapshot_id, path, filename, content_type, size_bytes, sha256, created_at
         FROM artifacts ORDER BY id",
    )
    .fetch_all(pool)
    .await?;

    Ok(ExportData { runs, snapshots, archive_results, artifacts })
}

#[derive(Debug, Deserialize)]
pub struct ImportSnapshot {
    pub url: String,
    pub profile: Option<String>,
    pub priority: Option<i32>,
    pub tags: Option<Vec<String>>,
}

pub async fn import_snapshots(
    pool: &PgPool,
    items: &[ImportSnapshot],
) -> Result<u64, sqlx::Error> {
    let mut count = 0u64;
    for item in items {
        let urls = vec![item.url.clone()];
        let tags = item.tags.clone().unwrap_or_default();
        create_run_with_snapshots(
            pool,
            &urls,
            item.profile.as_deref().unwrap_or("full"),
            item.priority.unwrap_or(0),
            &tags,
            None,
            "import",
        )
        .await?;
        count += 1;
    }
    Ok(count)
}
