use askama::Template;
use crate::db;

// --- Full page templates ---
//
// Every page template carries `active: &'static str` so base.html can
// highlight the matching link in the appbar. Possible values:
//   "jobs", "runs", "proxy", "nitter", "youtube", "logs", "proxylog", "help"
// (or empty when no nav item should be marked, e.g. /).

#[derive(Template)]
#[template(path = "index.html")]
pub struct IndexTemplate {
    pub active: &'static str,
    pub stats: db::DashboardStats,
    pub snapshots: Vec<db::Snapshot>,
}

#[derive(Template)]
#[template(path = "jobs_list.html")]
pub struct JobsListTemplate {
    pub active: &'static str,
    pub snapshots: Vec<db::Snapshot>,
    pub counts: db::StateCounts,
    pub filter: Option<String>,
    pub url_filter: String,
    pub tag_filter: String,
    pub run_filter: Option<i64>,
}

#[derive(Template)]
#[template(path = "jobs_new.html")]
pub struct JobsNewTemplate {
    pub active: &'static str,
    pub error: Option<String>,
}

#[derive(Template)]
#[template(path = "jobs_manual.html")]
pub struct JobsManualTemplate {
    pub active: &'static str,
    pub error: Option<String>,
}

#[derive(Template)]
#[template(path = "job_detail.html")]
pub struct JobDetailTemplate {
    pub active: &'static str,
    pub snapshot: Option<db::Snapshot>,
    pub results: Vec<db::ResultRow>,
    pub url_history: Vec<db::Snapshot>,
    /// Host part of the snapshot's URL — drives the v2-preview address bar.
    pub hostname: String,
    /// Sum of artifact sizes across this snapshot, formatted "5.0 MB".
    pub total_size: String,
    /// Wall-clock between earliest started_at and latest completed_at,
    /// formatted "8.0 s" for the section subtitle.
    pub duration: String,
    /// "N of M completed" rollup for the section subtitle.
    pub completed_summary: String,
    /// Pre-rendered "screenshot.png · 363.0 KB" caption, or None when no
    /// screenshot extractor row exists yet.
    pub screenshot_caption: Option<String>,
    /// URL of the real screenshot artifact (/artifacts/results/<id>/screenshot.png),
    /// or None when no completed screenshot extractor row exists yet. Drives
    /// the v2-preview image; falls back to the skeleton placeholder when None.
    pub screenshot_url: Option<String>,
    /// User-supplied content blobs attached at submission time. Empty
    /// for worker-driven snapshots; non-empty for manual ones.
    pub user_content: Vec<db::SnapshotUserContent>,
}

#[derive(Template)]
#[template(path = "runs_list.html")]
pub struct RunsListTemplate {
    pub active: &'static str,
    pub runs: Vec<db::Run>,
}

#[derive(Template)]
#[template(path = "run_detail.html")]
pub struct RunDetailTemplate {
    pub active: &'static str,
    pub run: Option<db::Run>,
    pub snapshots: Vec<db::Snapshot>,
    pub has_retriable: bool,
    pub has_active: bool,
}

#[derive(Template)]
#[template(path = "proxy_status.html")]
pub struct ProxyStatusTemplate {
    pub active: &'static str,
    pub health: db::ProxyHealth,
}

#[derive(Template)]
#[template(path = "nitter.html")]
pub struct NitterTemplate {
    pub active: &'static str,
    pub status: Option<db::NitterMintStatus>,
    pub override_row: Option<db::NitterCredsOverride>,
    pub trigger_path: String,
    pub egress: Option<db::ServiceEgressMode>,
}

#[derive(Template)]
#[template(path = "youtube.html")]
pub struct YoutubeTemplate {
    pub active: &'static str,
    pub auth: Option<db::YoutubeCompanionAuth>,
    pub pending: Option<db::YoutubeOauthPending>,
    pub status: Option<db::YoutubeCompanionStatus>,
    pub egress_companion: Option<db::ServiceEgressMode>,
    pub egress_invidious: Option<db::ServiceEgressMode>,
}

#[derive(Template)]
#[template(path = "logs.html")]
pub struct LogsTemplate {
    pub active: &'static str,
}

#[derive(Template)]
#[template(path = "help.html")]
pub struct HelpTemplate {
    pub active: &'static str,
}

// --- Htmx fragment templates ---

#[derive(Template)]
#[template(path = "fragments/job_table.html")]
pub struct JobTableFragment {
    pub snapshots: Vec<db::Snapshot>,
}

#[derive(Template)]
#[template(path = "fragments/proxy_status.html")]
pub struct ProxyStatusFragment {
    pub health: db::ProxyHealth,
}
