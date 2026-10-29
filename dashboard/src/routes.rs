use crate::{AppState, db, templates};
use axum::{
    Form,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{
        IntoResponse, Json, Redirect,
        sse::{Event, KeepAlive, Sse},
    },
};
use serde::Deserialize;
use std::sync::Arc;

type S = State<Arc<AppState>>;

async fn redirect_after<F: std::future::Future<Output = Result<(), sqlx::Error>>>(
    fut: F,
    to: String,
) -> Redirect {
    fut.await.unwrap();
    Redirect::to(&to)
}

pub async fn index(State(state): S) -> impl IntoResponse {
    let stats = db::get_stats(&state.db).await.unwrap();
    let snapshots = db::list_snapshots(&state.db, 5).await.unwrap();
    templates::IndexTemplate {
        active: "",
        stats,
        snapshots,
    }
}

#[derive(Deserialize)]
pub struct SnapshotsQuery {
    state: Option<String>,
    url: Option<String>,
    tag: Option<String>,
    run: Option<i64>,
}

pub async fn jobs_list(State(state): S, Query(q): Query<SnapshotsQuery>) -> impl IntoResponse {
    let url_f = q.url.as_deref().filter(|s| !s.is_empty());
    let tag_f = q.tag.as_deref().filter(|s| !s.is_empty());
    let state_f = q.state.as_deref().filter(|s| !s.is_empty());
    let snapshots = db::list_snapshots_filtered(&state.db, state_f, url_f, tag_f, q.run, 100)
        .await
        .unwrap();
    let counts = db::get_state_counts(&state.db).await.unwrap_or_default();
    templates::JobsListTemplate {
        active: "jobs",
        snapshots,
        counts,
        filter: q.state.filter(|s| !s.is_empty()),
        url_filter: q.url.filter(|s| !s.is_empty()).unwrap_or_default(),
        tag_filter: q.tag.filter(|s| !s.is_empty()).unwrap_or_default(),
        run_filter: q.run,
    }
}

#[derive(Deserialize)]
pub struct JobsNewQuery {
    error: Option<String>,
    profile: Option<String>,
}

pub async fn jobs_new_form(Query(q): Query<JobsNewQuery>) -> impl IntoResponse {
    let error = q.error.map(|code| match code.as_str() {
        "urls-empty" => "Submit at least one non-empty URL.".to_string(),
        "profile-unknown" => format!(
            "Unknown profile '{}'. Pick one from the dropdown.",
            q.profile.unwrap_or_default()
        ),
        "db" => "Database error while creating the run. Try again or check the logs.".to_string(),
        other => format!("Submission failed: {}", other),
    });
    templates::JobsNewTemplate {
        active: "jobs",
        error,
    }
}

pub async fn job_detail(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    let snapshot = db::get_snapshot(&state.db, id).await.unwrap();
    let results = db::get_snapshot_result_rows(&state.db, id).await.unwrap();
    let url_history = match &snapshot {
        Some(s) => db::list_url_history(&state.db, &s.url, s.id, 20)
            .await
            .unwrap_or_default(),
        None => Vec::new(),
    };
    let user_content = match &snapshot {
        Some(s) => db::get_snapshot_user_content(&state.db, s.id)
            .await
            .unwrap_or_default(),
        None => Vec::new(),
    };

    let hostname = snapshot
        .as_ref()
        .map(|s| extract_hostname(&s.url))
        .unwrap_or_default();
    let total_size = format_bytes(results.iter().filter_map(|r| r.size_bytes).sum::<i64>());
    let duration = compute_duration(&results);
    let completed_count = results.iter().filter(|r| r.is_completed()).count();
    let completed_summary = format!(
        "{} of {} completed{}",
        completed_count,
        results.len(),
        if duration.is_empty() {
            String::new()
        } else {
            format!(" · captured in {}", duration)
        }
    );
    let screenshot_result = results
        .iter()
        .find(|r| r.extractor == "screenshot" && r.is_completed());
    let screenshot_caption =
        screenshot_result.map(|r| format!("screenshot.png · {}", r.size_display()));
    let screenshot_url =
        screenshot_result.map(|r| format!("/artifacts/results/{}/screenshot.png", r.id));

    templates::JobDetailTemplate {
        active: "jobs",
        snapshot,
        results,
        url_history,
        hostname,
        total_size,
        duration,
        completed_summary,
        screenshot_caption,
        screenshot_url,
        user_content,
    }
}

/// Pull the hostname out of an absolute URL the cheap way — find the
/// `://` and clip up to the next `/` or `?`. Falls back to the whole
/// string if there's no scheme.
fn extract_hostname(url: &str) -> String {
    let after_scheme = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let host = after_scheme.split(['/', '?', '#']).next().unwrap_or("");
    host.to_string()
}

fn format_bytes(b: i64) -> String {
    match b {
        0 => "—".into(),
        b if b < 1024 => format!("{} B", b),
        b if b < 1024 * 1024 => format!("{:.1} KB", b as f64 / 1024.0),
        b if b < 1024 * 1024 * 1024 => format!("{:.1} MB", b as f64 / 1048576.0),
        b => format!("{:.2} GB", b as f64 / 1073741824.0),
    }
}

fn compute_duration(results: &[db::ResultRow]) -> String {
    let starts = results.iter().filter_map(|r| r.started_at).min();
    let ends = results.iter().filter_map(|r| r.completed_at).max();
    match (starts, ends) {
        (Some(s), Some(e)) if e >= s => {
            let secs = (e - s).num_seconds();
            if secs < 60 {
                format!("{:.1} s", secs as f64)
            } else if secs < 3600 {
                format!("{:.1} min", secs as f64 / 60.0)
            } else {
                format!("{:.1} h", secs as f64 / 3600.0)
            }
        }
        _ => String::new(),
    }
}

pub async fn runs_list(State(state): S) -> impl IntoResponse {
    let runs = db::list_runs(&state.db, 100).await.unwrap();
    templates::RunsListTemplate {
        active: "runs",
        runs,
    }
}

pub async fn run_detail(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    let run = db::get_run(&state.db, id).await.unwrap();
    let snapshots = db::list_run_snapshots(&state.db, id).await.unwrap();
    let has_retriable = snapshots
        .iter()
        .any(|s| s.state == "failed" || s.state == "partial" || s.state == "cancelled");
    let has_active = snapshots
        .iter()
        .any(|s| s.state == "pending" || s.state == "running");
    templates::RunDetailTemplate {
        active: "runs",
        run,
        snapshots,
        has_retriable,
        has_active,
    }
}

pub async fn proxy_status(State(state): S) -> impl IntoResponse {
    let health_json = tokio::fs::read_to_string(&state.proxy_health_path)
        .await
        .unwrap_or_else(|_| "{}".to_string());
    let health = db::parse_health(&health_json);
    templates::ProxyStatusTemplate {
        active: "proxy",
        health,
    }
}

pub async fn logs_page() -> impl IntoResponse {
    templates::LogsTemplate { active: "logs" }
}

/// All fetchproxies-relevant unit globs. The single /logs/stream
/// endpoint subscribes to this superset; per-connection routing
/// events (proxy-chain, mullvad relays, bright-data, http→socks
/// bridges, probe) are inside it, so the operator narrows via the
/// in-page category pills instead of a separate page.
const ALL_LOG_UNITS: &[&str] = &[
    "fetchproxies-*",
    "proxy-chain*",
    "proxy-wg-relay-*",
    "mullvad-extract-*",
    "mullvad-relay-*",
    "brightdata-relay",
    "nitter",
    "nitter-mint",
    "nitter-http-bridge",
    "nitter-sessions-reload",
    "redlib",
    "redlib-probe-*",
    "kiwix",
    "transmission*",
    "invidious*",
    "invidious-companion*",
    "invidious-http-bridge",
    "redis-*",
    "podman-*",
];

/// Spawn `journalctl --follow -o json` filtered to the given unit
/// Strip Go stdlib log's leading timestamp prefix from a message line.
/// gost (when run via CLI without a config file) prefixes every log
/// line with `YYYY/MM/DD HH:MM:SS[.ffffff] ` via Go's `LstdFlags |
/// Lmicroseconds`. The dashboard already renders `__REALTIME_TIMESTAMP`
/// in the row's leading column using the project-wide
/// `YYYY-MM-DD HH:MM:SS` shape, so the in-message copy is redundant
/// noise — and worse, in a different format.
///
/// Only strips when the line shape matches exactly. Anything that
/// doesn't look like a Go stdlib log (e.g. a service that emits its
/// own structured logs, or a journalctl entry without a service-side
/// timestamp) passes through untouched.
fn strip_log_ts_prefix(s: &str) -> &str {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'/'
        || b[7] != b'/'
        || b[10] != b' '
        || b[13] != b':'
        || b[16] != b':'
    {
        return s;
    }
    let digits = |range: std::ops::Range<usize>| range.into_iter().all(|i| b[i].is_ascii_digit());
    if !(digits(0..4)
        && digits(5..7)
        && digits(8..10)
        && digits(11..13)
        && digits(14..16)
        && digits(17..19))
    {
        return s;
    }
    let mut i = 19;
    if b.get(i) == Some(&b'.') {
        i += 1;
        while b.get(i).is_some_and(|c| c.is_ascii_digit()) {
            i += 1;
        }
    }
    if b.get(i) == Some(&b' ') {
        i += 1;
    }
    &s[i..]
}

/// globs, parse each emitted record, and emit a slim per-event SSE
/// payload. The slim payload is itself one JSON object per `data:`
/// line so the client can JSON.parse it cheaply.
///
/// Source override: `JOURNAL_COMMAND` (or per-stream
/// `JOURNAL_COMMAND_LOGS` / `JOURNAL_COMMAND_PROXY` for the two
/// endpoints) replaces the journalctl invocation. The value is
/// shell-split (whitespace-separated; quoting not honoured — keep
/// args simple); the command is expected to print one
/// journalctl-shape JSON object per line on stdout, forever. Used by
/// dev/preview.sh to feed synthetic events when there's no real
/// journald to read from.
fn journal_sse(units: &'static [&'static str], override_var: &'static str) -> impl IntoResponse {
    let stream = async_stream::stream! {
        let override_cmd = std::env::var(override_var)
            .ok()
            .or_else(|| std::env::var("JOURNAL_COMMAND").ok());
        let mut cmd = if let Some(s) = override_cmd.as_deref() {
            let mut parts = s.split_whitespace();
            let head = parts.next().unwrap_or("true");
            let mut c = tokio::process::Command::new(head);
            for arg in parts { c.arg(arg); }
            c
        } else {
            let mut c = tokio::process::Command::new("journalctl");
            c.arg("--follow")
                .arg("--no-pager")
                .arg("-o").arg("json")
                .arg("-n").arg("80");
            for u in units {
                c.arg("-u").arg(*u);
            }
            c
        };
        let mut child = match cmd
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                let payload = serde_json::json!({
                    "ts": null,
                    "unit": "dashboard",
                    "level": "err",
                    "msg": format!("journalctl spawn failed: {}", e),
                });
                yield Ok::<_, std::convert::Infallible>(Event::default().data(payload.to_string()));
                return;
            }
        };

        let stdout = child.stdout.take().unwrap();
        let reader = tokio::io::BufReader::new(stdout);
        let mut lines = tokio::io::AsyncBufReadExt::lines(reader);

        while let Ok(Some(line)) = lines.next_line().await {
            let v: serde_json::Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let ts_us: i64 = v
                .get("__REALTIME_TIMESTAMP")
                .and_then(|x| x.as_str())
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let unit = v
                .get("_SYSTEMD_UNIT")
                .or_else(|| v.get("UNIT"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .trim_end_matches(".service");
            let level = v
                .get("PRIORITY")
                .and_then(|x| x.as_str())
                .unwrap_or("6");
            let raw_msg = v
                .get("MESSAGE")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            let msg = strip_log_ts_prefix(raw_msg);

            let gost = serde_json::from_str::<serde_json::Value>(raw_msg).ok();

            let payload = serde_json::json!({
                "ts_us": ts_us,
                "unit": unit,
                "level": level,
                "msg": msg,
                "gost": gost,
            });
            yield Ok::<_, std::convert::Infallible>(Event::default().data(payload.to_string()));
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::default())
}

pub async fn logs_stream() -> impl IntoResponse {
    journal_sse(ALL_LOG_UNITS, "JOURNAL_COMMAND_LOGS")
}

pub async fn fragment_job_table(
    State(state): S,
    Query(q): Query<SnapshotsQuery>,
) -> impl IntoResponse {
    let url_f = q.url.as_deref().filter(|s| !s.is_empty());
    let tag_f = q.tag.as_deref().filter(|s| !s.is_empty());
    let state_f = q.state.as_deref().filter(|s| !s.is_empty());
    let any_filter = state_f.is_some() || url_f.is_some() || tag_f.is_some() || q.run.is_some();
    let snapshots = if any_filter {
        db::list_snapshots_filtered(&state.db, state_f, url_f, tag_f, q.run, 100)
            .await
            .unwrap()
    } else {
        db::list_snapshots(&state.db, 20).await.unwrap()
    };
    templates::JobTableFragment { snapshots }
}

pub async fn fragment_proxy_status(State(state): S) -> impl IntoResponse {
    let health_json = tokio::fs::read_to_string(&state.proxy_health_path)
        .await
        .unwrap_or_else(|_| "{}".to_string());
    let health = db::parse_health(&health_json);
    templates::ProxyStatusFragment { health }
}

#[derive(Deserialize)]
pub struct CreateJobsForm {
    urls: String,
    profile: Option<String>,
    priority: Option<i32>,
    tags: Option<String>,
    proxy_chain: Option<String>,
}

fn parse_tags(raw: Option<&str>) -> Vec<String> {
    raw.unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn parse_urls(raw: &str) -> Vec<String> {
    raw.lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

pub async fn api_create_jobs_batch(
    State(state): S,
    Form(form): Form<CreateJobsForm>,
) -> impl IntoResponse {
    let urls = parse_urls(&form.urls);
    if urls.is_empty() {
        return Redirect::to("/jobs/new?error=urls-empty");
    }
    let tags = parse_tags(form.tags.as_deref());
    let profile = form.profile.unwrap_or_else(|| "full".to_string());
    let proxy_chain = form.proxy_chain.as_deref().filter(|s| !s.is_empty());

    match db::create_run_with_snapshots(
        &state.db,
        &urls,
        &profile,
        form.priority.unwrap_or(0),
        &tags,
        proxy_chain,
        "api",
    )
    .await
    {
        Ok((run_id, _)) => Redirect::to(&format!("/runs/{}", run_id)),
        Err(sqlx::Error::RowNotFound) => Redirect::to(&format!(
            "/jobs/new?error=profile-unknown&profile={}",
            profile
        )),
        Err(_) => Redirect::to("/jobs/new?error=db"),
    }
}

#[derive(Deserialize)]
pub struct JobsManualQuery {
    error: Option<String>,
}

pub async fn jobs_manual_form(Query(q): Query<JobsManualQuery>) -> impl IntoResponse {
    let error = q.error.map(|code| match code.as_str() {
        "url-empty" => {
            "Submit a URL — manual snapshots still need a stable identifier.".to_string()
        }
        "no-content" => {
            "Provide at least one of: title, HTML, markdown, or a custom blob.".to_string()
        }
        "db" => "Database error while saving the manual snapshot. Try again or check the logs."
            .to_string(),
        other => format!("Submission failed: {}", other),
    });
    templates::JobsManualTemplate {
        active: "jobs",
        error,
    }
}

#[derive(Deserialize)]
pub struct CreateManualForm {
    url: String,
    title: Option<String>,
    html: Option<String>,
    markdown: Option<String>,
    /// Pairs of `custom_keys[]` + `custom_contents[]` from the form.
    /// HTML form arrays show up as repeated fields with the same name;
    /// serde collects them into Vec when the field is `Vec<String>`.
    #[serde(default, rename = "custom_keys[]")]
    custom_keys: Vec<String>,
    #[serde(default, rename = "custom_contents[]")]
    custom_contents: Vec<String>,
    tags: Option<String>,
    priority: Option<i32>,
}

fn collect_manual_contents(form: &CreateManualForm) -> Vec<db::ManualContent> {
    let mut out: Vec<db::ManualContent> = Vec::new();
    if let Some(h) = form.html.as_ref().filter(|s| !s.is_empty()) {
        out.push(db::ManualContent {
            key: "html".to_string(),
            content: h.clone(),
            mime_type: Some("text/html".to_string()),
        });
    }
    if let Some(m) = form.markdown.as_ref().filter(|s| !s.is_empty()) {
        out.push(db::ManualContent {
            key: "markdown".to_string(),
            content: m.clone(),
            mime_type: Some("text/markdown".to_string()),
        });
    }
    for (k, c) in form.custom_keys.iter().zip(form.custom_contents.iter()) {
        let key = k.trim();
        if key.is_empty() || c.is_empty() || key == "html" || key == "markdown" {
            continue;
        }
        out.push(db::ManualContent {
            key: key.to_string(),
            content: c.clone(),
            mime_type: None,
        });
    }
    out
}

pub async fn api_create_manual_snapshot(
    State(state): S,
    Form(form): Form<CreateManualForm>,
) -> impl IntoResponse {
    let url = form.url.trim();
    if url.is_empty() {
        return Redirect::to("/jobs/manual?error=url-empty");
    }
    let title = form
        .title
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    let contents = collect_manual_contents(&form);
    if title.is_none() && contents.is_empty() {
        return Redirect::to("/jobs/manual?error=no-content");
    }
    let tags = parse_tags(form.tags.as_deref());

    match db::create_manual_snapshot(
        &state.db,
        url,
        title,
        &contents,
        &tags,
        form.priority.unwrap_or(0),
        "manual",
    )
    .await
    {
        Ok((_run_id, snapshot_id)) => Redirect::to(&format!("/jobs/{}", snapshot_id)),
        Err(_) => Redirect::to("/jobs/manual?error=db"),
    }
}

#[derive(Deserialize)]
pub struct ManualContentJson {
    pub key: String,
    pub content: String,
    pub mime_type: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateManualJsonBody {
    pub url: String,
    pub title: Option<String>,
    pub html: Option<String>,
    pub markdown: Option<String>,
    #[serde(default)]
    pub custom_contents: Vec<ManualContentJson>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub priority: Option<i32>,
}

pub async fn api_json_create_manual_snapshot(
    State(state): S,
    Json(body): Json<CreateManualJsonBody>,
) -> impl IntoResponse {
    let url = body.url.trim();
    if url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "url is required"})),
        )
            .into_response();
    }
    let title = body
        .title
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    let mut contents: Vec<db::ManualContent> = Vec::new();
    if let Some(h) = body.html.as_ref().filter(|s| !s.is_empty()) {
        contents.push(db::ManualContent {
            key: "html".to_string(),
            content: h.clone(),
            mime_type: Some("text/html".to_string()),
        });
    }
    if let Some(m) = body.markdown.as_ref().filter(|s| !s.is_empty()) {
        contents.push(db::ManualContent {
            key: "markdown".to_string(),
            content: m.clone(),
            mime_type: Some("text/markdown".to_string()),
        });
    }
    for c in &body.custom_contents {
        let key = c.key.trim();
        if key.is_empty() || c.content.is_empty() || key == "html" || key == "markdown" {
            continue;
        }
        contents.push(db::ManualContent {
            key: key.to_string(),
            content: c.content.clone(),
            mime_type: c.mime_type.clone(),
        });
    }
    if title.is_none() && contents.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "supply at least a title or one content blob"})),
        )
            .into_response();
    }
    match db::create_manual_snapshot(
        &state.db,
        url,
        title,
        &contents,
        &body.tags,
        body.priority.unwrap_or(0),
        "api",
    )
    .await
    {
        Ok((run_id, snapshot_id)) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "run_id": run_id,
                "snapshot_id": snapshot_id,
                "content_keys": contents.iter().map(|c| &c.key).collect::<Vec<_>>(),
            })),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("db: {}", e)})),
        )
            .into_response(),
    }
}

pub async fn api_retry_snapshot(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::retry_snapshot(&state.db, id), format!("/jobs/{}", id)).await
}

pub async fn api_retry_result(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    let snapshot_id: Option<i64> =
        sqlx::query_scalar("SELECT snapshot_id FROM archive_results WHERE id = $1")
            .bind(id)
            .fetch_optional(&state.db)
            .await
            .unwrap_or(None);
    db::retry_result(&state.db, id).await.unwrap();
    match snapshot_id {
        Some(s) => Redirect::to(&format!("/jobs/{}", s)),
        None => Redirect::to("/jobs"),
    }
}

pub async fn api_cancel_snapshot(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::cancel_snapshot(&state.db, id), format!("/jobs/{}", id)).await
}

pub async fn api_delete_snapshot(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::delete_snapshot(&state.db, id), "/jobs".to_string()).await
}

#[derive(Deserialize, Default)]
pub struct RearchiveForm {
    #[serde(default)]
    profile: Option<String>,
}

pub async fn api_rearchive_snapshot(
    State(state): S,
    Path(id): Path<i64>,
    form: Result<Form<RearchiveForm>, axum::extract::rejection::FormRejection>,
) -> impl IntoResponse {
    let form = form.map(|Form(f)| f).unwrap_or_default();
    let profile = form.profile.as_deref().filter(|s| !s.is_empty());
    match db::rearchive_snapshot(&state.db, id, profile).await {
        Ok(new_id) => Redirect::to(&format!("/jobs/{}", new_id)),
        Err(sqlx::Error::RowNotFound) => {
            Redirect::to(&format!("/jobs/{}?error=profile-unknown", id))
        }
        Err(_) => Redirect::to(&format!("/jobs/{}", id)),
    }
}

pub async fn api_retry_run(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::retry_run(&state.db, id), format!("/runs/{}", id)).await
}

pub async fn api_cancel_run(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::cancel_run(&state.db, id), format!("/runs/{}", id)).await
}

pub async fn api_delete_run(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    redirect_after(db::delete_run(&state.db, id), "/runs".to_string()).await
}

pub async fn nitter_page(State(state): S) -> impl IntoResponse {
    let status = db::get_nitter_mint_status(&state.db).await.unwrap_or(None);
    let override_row = db::get_nitter_creds_override(&state.db)
        .await
        .unwrap_or(None);
    let egress = db::get_egress_mode(&state.db, "nitter")
        .await
        .unwrap_or(None);
    templates::NitterTemplate {
        active: "nitter",
        status,
        override_row,
        trigger_path: state.nitter_trigger_path.clone(),
        egress,
    }
}

pub async fn api_nitter_trigger(State(state): S) -> impl IntoResponse {
    let _ = tokio::fs::write(&state.nitter_trigger_path, "").await;
    Redirect::to("/nitter")
}

#[derive(Deserialize)]
pub struct NitterOverrideForm {
    pub action: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub totp_secret: Option<String>,
}

pub async fn api_nitter_override(
    State(state): S,
    Form(form): Form<NitterOverrideForm>,
) -> impl IntoResponse {
    if form.action == "clear" {
        let _ = db::clear_nitter_override(&state.db).await;
    } else {
        let _ = db::upsert_nitter_override(
            &state.db,
            form.username.as_deref().unwrap_or(""),
            form.password.as_deref().unwrap_or(""),
            form.totp_secret.as_deref().unwrap_or(""),
            "use_override",
        )
        .await;
    }
    Redirect::to("/nitter")
}

#[derive(Deserialize)]
pub struct EgressForm {
    pub mode: String,
    pub reason: Option<String>,
}

pub async fn api_set_egress(
    State(state): S,
    Path(service): Path<String>,
    Form(form): Form<EgressForm>,
) -> impl IntoResponse {
    let valid_service = matches!(service.as_str(), "nitter" | "invidious" | "companion");
    let valid_mode = matches!(form.mode.as_str(), "proxy_chain" | "direct");
    if !valid_service || !valid_mode {
        return (StatusCode::BAD_REQUEST, "invalid service or mode").into_response();
    }
    let _ = db::set_egress_mode(
        &state.db,
        &service,
        &form.mode,
        form.reason.as_deref().filter(|s| !s.is_empty()),
    )
    .await;
    crate::supervisor::regenerate_all(&state.db).await;
    let redirect = if service == "nitter" {
        "/nitter"
    } else {
        "/youtube"
    };
    Redirect::to(redirect).into_response()
}

pub async fn youtube_page(State(state): S) -> impl IntoResponse {
    let auth = db::get_youtube_auth(&state.db).await.unwrap_or(None);
    let pending = db::get_youtube_oauth_pending(&state.db)
        .await
        .unwrap_or(None);
    let status = db::get_youtube_companion_status(&state.db)
        .await
        .unwrap_or(None);
    let egress_companion = db::get_egress_mode(&state.db, "companion")
        .await
        .unwrap_or(None);
    let egress_invidious = db::get_egress_mode(&state.db, "invidious")
        .await
        .unwrap_or(None);
    templates::YoutubeTemplate {
        active: "youtube",
        auth,
        pending,
        status,
        egress_companion,
        egress_invidious,
    }
}

pub async fn api_youtube_oauth_start(State(state): S) -> impl IntoResponse {
    let _ = db::upsert_youtube_oauth_token(
        &state.db,
        "",
        None,
        None,
        Some("https://www.googleapis.com/auth/youtube"),
        None,
    )
    .await;
    crate::supervisor::regenerate_all(&state.db).await;
    Redirect::to("/youtube").into_response()
}

#[derive(Deserialize)]
pub struct ManualRefreshTokenForm {
    pub refresh_token: String,
    pub account_email: Option<String>,
}

pub async fn api_youtube_oauth_manual(
    State(state): S,
    Form(form): Form<ManualRefreshTokenForm>,
) -> impl IntoResponse {
    if form.refresh_token.trim().is_empty() {
        return (StatusCode::BAD_REQUEST, "refresh_token required").into_response();
    }
    let _ = db::upsert_youtube_oauth_token(
        &state.db,
        form.refresh_token.trim(),
        None,
        None,
        Some("https://www.googleapis.com/auth/youtube"),
        form.account_email.as_deref().filter(|s| !s.is_empty()),
    )
    .await;
    crate::supervisor::regenerate_all(&state.db).await;
    Redirect::to("/youtube").into_response()
}

#[derive(Deserialize)]
pub struct YoutubeCookiesForm {
    pub cookies: String,
}

pub async fn api_youtube_cookies(
    State(state): S,
    Form(form): Form<YoutubeCookiesForm>,
) -> impl IntoResponse {
    if form.cookies.trim().is_empty() {
        return (StatusCode::BAD_REQUEST, "cookies required").into_response();
    }
    let _ = db::upsert_youtube_cookies(&state.db, form.cookies.trim()).await;
    crate::supervisor::regenerate_all(&state.db).await;
    Redirect::to("/youtube").into_response()
}

pub async fn api_youtube_clear(State(state): S) -> impl IntoResponse {
    let _ = db::clear_youtube_auth(&state.db).await;
    crate::supervisor::regenerate_all(&state.db).await;
    Redirect::to("/youtube").into_response()
}

pub async fn api_json_stats(State(state): S) -> impl IntoResponse {
    match db::get_stats(&state.db).await {
        Ok(stats) => Json(stats).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_proxy_health(State(state): S) -> impl IntoResponse {
    let health = tokio::fs::read_to_string(&state.proxy_health_path)
        .await
        .unwrap_or_else(|_| "{}".to_string());
    ([("content-type", "application/json")], health)
}

pub async fn api_json_snapshots(State(state): S) -> impl IntoResponse {
    match db::list_snapshots(&state.db, 100).await {
        Ok(s) => Json(s).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_snapshot(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    match db::get_snapshot(&state.db, id).await {
        Ok(Some(s)) => Json(s).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_snapshot_results(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    match db::get_snapshot_results(&state.db, id).await {
        Ok(r) => Json(r).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_snapshot_artifacts(
    State(state): S,
    Path(id): Path<i64>,
) -> impl IntoResponse {
    match db::get_snapshot_artifacts(&state.db, id).await {
        Ok(a) => Json(a).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// Where a result's archive listing is browsed: the link the worker baked
/// into the rendition when it is absolute, else `/artifacts/results/<id>/`
/// under the dashboard's PUBLIC_URL, else that path alone.
fn archive_url(result_id: i64, baked: Option<&str>, public_url: Option<&str>) -> String {
    if let Some(b) = baked.filter(|b| b.starts_with("https://") || b.starts_with("http://")) {
        return b.to_string();
    }
    let path = format!("/artifacts/results/{}/", result_id);
    match public_url.filter(|u| !u.is_empty()) {
        Some(base) => format!("{}{}", base.trim_end_matches('/'), path),
        None => path,
    }
}

/// `missing` when the snapshot has no markdown row (its profile lacked the
/// extractor), otherwise the row's queue state.
fn markdown_state(m: &db::MarkdownStatus) -> &str {
    match (m.result_state.as_deref(), m.meta.is_some()) {
        (None, _) | (Some("completed"), false) => "missing",
        (Some(s), _) => s,
    }
}

fn markdown_status_json(m: &db::MarkdownStatus, public_url: Option<&str>) -> serde_json::Value {
    let meta = m.meta.clone().unwrap_or(serde_json::Value::Null);
    let field = |k: &str| meta.get(k).cloned().unwrap_or(serde_json::Value::Null);
    let state = markdown_state(m);
    let fetched_at = match meta.get("fetched_at") {
        Some(v) if v.is_string() => v.clone(),
        _ => m
            .completed_at
            .map(|t| serde_json::Value::String(t.format("%Y-%m-%dT%H:%M:%SZ").to_string()))
            .unwrap_or(serde_json::Value::Null),
    };
    serde_json::json!({
        "snapshot_id": m.snapshot_id,
        "url": m.url,
        "state": state,
        "result_id": m.result_id,
        "error": m.error,
        "fetched_at": fetched_at,
        "title": field("title"),
        "final_url": field("final_url"),
        "http_status": field("http_status"),
        "content_type": field("content_type"),
        "rendition": field("rendition"),
        "truncated": field("truncated"),
        "size_bytes": m.size_bytes,
        "archive_url": m.result_id.map(|id| archive_url(id, meta.get("archive").and_then(|v| v.as_str()), public_url)),
        "markdown_url": m.result_id.filter(|_| state == "completed").map(|id| format!("/api/v1/results/{}/markdown", id)),
    })
}

/// `max_age` defaults to a day and is held to 0..=30 days.
fn clamp_max_age(v: Option<i64>) -> i64 {
    v.unwrap_or(86_400).clamp(0, 30 * 86_400)
}

pub async fn api_json_snapshot_markdown(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    match db::get_snapshot_markdown(&state.db, id).await {
        Ok(Some(m)) => Json(markdown_status_json(&m, state.public_url.as_deref())).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "no such snapshot"})),
        )
            .into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
pub struct MarkdownLookup {
    url: String,
    max_age: Option<i64>,
}

pub async fn api_json_markdown_lookup(
    State(state): S,
    Query(q): Query<MarkdownLookup>,
) -> impl IntoResponse {
    let url = q.url.trim();
    if url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "url is required"})),
        )
            .into_response();
    }
    match db::find_fresh_markdown(&state.db, url, clamp_max_age(q.max_age)).await {
        Ok(Some(m)) => Json(markdown_status_json(&m, state.public_url.as_deref())).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "no markdown rendition of this URL within max_age"})),
        )
            .into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_result_markdown(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    match db::get_result_markdown(&state.db, id).await {
        Ok(Some(md)) => (
            [(
                axum::http::header::CONTENT_TYPE,
                "text/markdown; charset=utf-8",
            )],
            md,
        )
            .into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            "no markdown rendition for this result",
        )
            .into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_runs(State(state): S) -> impl IntoResponse {
    match db::list_runs(&state.db, 100).await {
        Ok(r) => Json(r).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_run(State(state): S, Path(id): Path<i64>) -> impl IntoResponse {
    match db::get_run(&state.db, id).await {
        Ok(Some(r)) => {
            let snapshots = db::list_run_snapshots(&state.db, id)
                .await
                .unwrap_or_default();
            Json(serde_json::json!({"run": r, "snapshots": snapshots})).into_response()
        }
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_json_profiles(State(state): S) -> impl IntoResponse {
    match db::list_profiles(&state.db).await {
        Ok(p) => Json(p).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
pub struct CreateSnapshotJson {
    url: Option<String>,
    urls: Option<Vec<String>>,
    profile: Option<String>,
    priority: Option<i32>,
    tags: Option<Vec<String>>,
    proxy_chain: Option<String>,
}

pub async fn api_json_create_snapshot(
    State(state): S,
    Json(body): Json<CreateSnapshotJson>,
) -> impl IntoResponse {
    let urls: Vec<String> = match (body.url, body.urls) {
        (_, Some(us)) => us,
        (Some(u), None) => vec![u],
        (None, None) => {
            return (StatusCode::BAD_REQUEST, "must supply url or urls").into_response();
        }
    }
    .into_iter()
    .filter(|u| !u.is_empty())
    .collect();

    if urls.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            "urls must contain at least one non-empty URL",
        )
            .into_response();
    }

    let tags = body.tags.unwrap_or_default();
    let proxy_chain = body.proxy_chain.as_deref().filter(|s| !s.is_empty());
    match db::create_run_with_snapshots(
        &state.db,
        &urls,
        body.profile.as_deref().unwrap_or("full"),
        body.priority.unwrap_or(0),
        &tags,
        proxy_chain,
        "api",
    )
    .await
    {
        Ok((run_id, snap_ids)) => (
            StatusCode::CREATED,
            Json(serde_json::json!({"run_id": run_id, "snapshot_ids": snap_ids})),
        )
            .into_response(),
        Err(sqlx::Error::RowNotFound) => (
            StatusCode::BAD_REQUEST,
            format!(
                "unknown profile '{}'",
                body.profile.as_deref().unwrap_or("full")
            ),
        )
            .into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    }
}

pub async fn api_export(State(state): S) -> impl IntoResponse {
    match db::export_all(&state.db).await {
        Ok(data) => Json(data).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

pub async fn api_import_snapshots(
    State(state): S,
    Json(items): Json<Vec<db::ImportSnapshot>>,
) -> impl IntoResponse {
    match db::import_snapshots(&state.db, &items).await {
        Ok(count) => Json(serde_json::json!({"imported": count})).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    }
}

pub async fn openapi_spec() -> impl IntoResponse {
    ([("content-type", "application/json")], OPENAPI_JSON)
}

const OPENAPI_JSON: &str = r##"{
  "openapi": "3.0.3",
  "info": {
    "title": "Fetchproxies API",
    "description": "Privacy archive — runs of snapshots, per-extractor results, proxy-chain health, nitter mint controls",
    "version": "0.4.0"
  },
  "components": {
    "schemas": {
      "CreateSnapshot": {
        "type": "object",
        "properties": {
          "url":         { "type": "string", "description": "Single URL to archive (one of url or urls is required)" },
          "urls":        { "type": "array", "items": { "type": "string" }, "description": "Multiple URLs; all share profile/tags/proxy_chain and land in one run" },
          "profile":     { "type": "string", "enum": ["full","compare","lightweight","warc_only","media","screenshots","bd_only","agent"], "default": "full" },
          "priority":    { "type": "integer", "default": 0, "minimum": -10, "maximum": 10 },
          "tags":        { "type": "array", "items": { "type": "string" } },
          "proxy_chain": { "type": "string", "description": "Optional SOCKS URL applied to every fanned-out extractor row, overriding the archiver default (socks5://127.0.0.1:1083)" }
        }
      }
    }
  },
  "paths": {
    "/api/v1/stats":           { "get": { "summary": "Snapshot + artifact counts", "responses": { "200": { "description": "Counts" } } } },

    "/api/v1/snapshots": {
      "get":  {
        "summary": "List recent snapshots",
        "parameters": [
          { "name": "state", "in": "query", "schema": { "type": "string", "enum": ["pending","running","completed","partial","failed","cancelled"] } },
          { "name": "url",   "in": "query", "schema": { "type": "string" }, "description": "URL substring (LIKE %x%)" },
          { "name": "tag",   "in": "query", "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "Array of snapshots" } }
      },
      "post": {
        "summary": "Create a run with one or more snapshots (fans out into one archive_result per extractor in the profile)",
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/CreateSnapshot" } } } },
        "responses":   { "201": { "description": "{ run_id, snapshot_ids[] }" } }
      }
    },
    "/api/v1/snapshots/{id}":           { "get": { "summary": "One snapshot",          "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"Snapshot"}, "404":{"description":"Not found"} } } },
    "/api/v1/snapshots/{id}/results":   { "get": { "summary": "Per-extractor results", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"Array"} } } },
    "/api/v1/snapshots/{id}/artifacts": { "get": { "summary": "Artifacts",             "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"Array"} } } },
    "/api/v1/snapshots/{id}/markdown":  { "get": { "summary": "The snapshot's markdown rendition: state (pending, running, completed, failed, skipped, missing), result_id, fetched_at, title, archive_url, markdown_url", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"MarkdownStatus"}, "404":{"description":"No such snapshot"} } } },
    "/api/v1/markdown": {
      "get": { "summary": "Newest completed markdown rendition of exactly this URL",
               "parameters": [
                 { "name": "url",     "in": "query", "required": true, "schema": { "type": "string" } },
                 { "name": "max_age", "in": "query", "schema": { "type": "integer", "default": 86400, "minimum": 0, "maximum": 2592000 }, "description": "Seconds since the rendition completed" }
               ],
               "responses": { "200": { "description": "MarkdownStatus" }, "404": { "description": "None within max_age" } } }
    },
    "/api/v1/results/{id}/markdown": { "get": { "summary": "The rendition itself (text/markdown; front matter, then the page); /api/results/{id}/markdown is the same", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"text/markdown"}, "404":{"description":"No rendition for this result"} } } },

    "/api/v1/runs":      { "get": { "summary": "List recent runs",                       "responses": { "200": { "description": "Array" } } } },
    "/api/v1/runs/{id}": { "get": { "summary": "Run detail with embedded snapshots[]", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "200": {"description":"{run, snapshots}"}, "404":{"description":"Not found"} } } },

    "/api/v1/profiles": { "get": { "summary": "List profiles", "responses": { "200": { "description": "Array" } } } },

    "/api/v1/proxy/health": { "get": { "summary": "Per-backend health snapshot (raw JSON from proxy-probe)", "responses": { "200": { "description": "Health JSON" } } } },

    "/api/v1/export": {
      "get": { "summary": "Full DB dump as JSON (runs, snapshots, archive_results, artifacts)",
               "description": "Use for backup or migration.",
               "responses": { "200": { "description": "ExportData" } } }
    },
    "/api/v1/import/snapshots": {
      "post": {
        "summary": "Bulk-create snapshots (each item lands in its own one-snapshot run)",
        "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "array", "items": { "$ref": "#/components/schemas/CreateSnapshot" } } } } },
        "responses":   { "200": { "description": "{ imported: <count> }" } }
      }
    },

    "/api/snapshots/{id}/retry":     { "post": { "summary": "Re-queue every failed/skipped result on this snapshot", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /jobs/{id}" } } } },
    "/api/snapshots/{id}/cancel":    { "post": { "summary": "Mark pending+running results as 'skipped'",            "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /jobs/{id}" } } } },
    "/api/snapshots/{id}/delete":    { "post": { "summary": "Delete snapshot (cascades results + artifact rows)",   "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /jobs" } } } },
    "/api/snapshots/{id}/rearchive": { "post": { "summary": "Create a new single-snapshot run with same URL/tags/proxy_chain; extractors inferred from existing results", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /jobs/<new_id>" } } } },

    "/api/results/{id}/retry": { "post": { "summary": "Re-queue a single archive_result row", "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to parent /jobs/{snapshot_id}" } } } },

    "/api/runs/{id}/retry":  { "post": { "summary": "Re-queue every failed/skipped result across all snapshots in this run",  "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /runs/{id}" } } } },
    "/api/runs/{id}/cancel": { "post": { "summary": "Mark every pending/running result in this run as skipped",              "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /runs/{id}" } } } },
    "/api/runs/{id}/delete": { "post": { "summary": "Delete the run (cascades all snapshots + their results + artifacts)",   "parameters": [ { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ], "responses": { "303": { "description": "Redirect to /runs" } } } },

    "/api/nitter/trigger": {
      "post": { "summary": "Force a nitter session-mint run (bypasses the 24h cooldown)",
                "responses": { "303": { "description": "Redirect to /nitter" } } }
    },
    "/api/nitter/override": {
      "post": {
        "summary": "Set or clear dashboard credential override for nitter mint",
        "requestBody": {
          "required": true,
          "content": {
            "application/x-www-form-urlencoded": {
              "schema": {
                "type": "object",
                "required": ["action"],
                "properties": {
                  "action":      { "type": "string", "enum": ["save","clear"] },
                  "username":    { "type": "string" },
                  "password":    { "type": "string", "format": "password" },
                  "totp_secret": { "type": "string", "description": "Base32 TOTP shared secret" }
                }
              }
            }
          }
        },
        "responses": { "303": { "description": "Redirect to /nitter" } }
      }
    },

    "/api/jobs": { "post": { "summary": "Create a run via HTML form (newline-separated 'urls' textarea + form-encoded profile/tags/proxy_chain). Auto-prepends batch-YYYY-MM-DD-HHMM to tags.", "responses": { "303": { "description": "Redirect to /runs/{id}" } } } }
  }
}"##;

pub async fn help_page() -> impl IntoResponse {
    templates::HelpTemplate { active: "help" }
}

pub async fn proxy_log_page() -> impl IntoResponse {
    Redirect::to("/logs")
}

pub async fn proxy_log_stream() -> impl IntoResponse {
    journal_sse(ALL_LOG_UNITS, "JOURNAL_COMMAND_LOGS")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(state: Option<&str>, meta: Option<serde_json::Value>) -> db::MarkdownStatus {
        db::MarkdownStatus {
            snapshot_id: 3,
            url: "https://example.com/".into(),
            result_id: state.map(|_| 7),
            result_state: state.map(String::from),
            error: None,
            completed_at: chrono::NaiveDate::from_ymd_opt(2026, 10, 29)
                .and_then(|d| d.and_hms_opt(10, 0, 0)),
            meta,
            size_bytes: Some(1234),
        }
    }

    #[test]
    fn archive_links_prefer_the_baked_absolute_url() {
        assert_eq!(
            archive_url(7, Some("https://fetch.example/artifacts/results/7/"), Some("https://other")),
            "https://fetch.example/artifacts/results/7/"
        );
        assert_eq!(
            archive_url(7, Some("/artifacts/results/7/"), Some("https://fetch.example/")),
            "https://fetch.example/artifacts/results/7/"
        );
        assert_eq!(archive_url(7, None, None), "/artifacts/results/7/");
    }

    #[test]
    fn markdown_status_reports_state_and_links() {
        let meta = serde_json::json!({"title": "T", "fetched_at": "2026-10-29T09:59:00Z", "http_status": 200,
                                      "archive": "/artifacts/results/7/", "truncated": false});
        let done = markdown_status_json(&status(Some("completed"), Some(meta)), Some("https://fetch.example"));
        assert_eq!(done["state"], "completed");
        assert_eq!(done["title"], "T");
        assert_eq!(done["fetched_at"], "2026-10-29T09:59:00Z");
        assert_eq!(done["archive_url"], "https://fetch.example/artifacts/results/7/");
        assert_eq!(done["markdown_url"], "/api/v1/results/7/markdown");

        let running = markdown_status_json(&status(Some("running"), None), None);
        assert_eq!(running["state"], "running");
        assert!(running["markdown_url"].is_null());

        let missing = markdown_status_json(&status(None, None), None);
        assert_eq!(missing["state"], "missing");
        assert!(missing["archive_url"].is_null());

        let no_meta = markdown_status_json(&status(Some("completed"), None), None);
        assert_eq!(no_meta["state"], "missing");
        assert_eq!(no_meta["fetched_at"], "2026-10-29T10:00:00Z");
    }

    #[test]
    fn max_age_is_bounded() {
        assert_eq!(clamp_max_age(None), 86_400);
        assert_eq!(clamp_max_age(Some(-5)), 0);
        assert_eq!(clamp_max_age(Some(i64::MAX)), 30 * 86_400);
    }
}
