use crate::db;
use chrono::NaiveDateTime;
use minijinja::value::Serde;
use minijinja::{Environment, UndefinedBehavior};
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

macro_rules! embedded {
    ($env:ident, $($name:literal),* $(,)?) => {$(
        $env.add_template($name, include_str!(concat!("../templates/", $name)))
            .expect(concat!("template ", $name));
    )*};
}

static ENV: LazyLock<Environment<'static>> = LazyLock::new(|| {
    let mut env = Environment::new();
    env.set_undefined_behavior(UndefinedBehavior::Strict);
    embedded!(
        env,
        "base.html",
        "index.html",
        "jobs_list.html",
        "jobs_new.html",
        "jobs_manual.html",
        "job_detail.html",
        "runs_list.html",
        "run_detail.html",
        "proxy_status.html",
        "nitter.html",
        "youtube.html",
        "_youtube_wizard.html",
        "logs.html",
        "help.html",
        "fragments/job_table.html",
        "fragments/log_stream.html",
        "fragments/proxy_status.html",
        "fragments/state_pill.html",
        "fragments/icons/activity.html",
        "fragments/icons/arrow_right.html",
        "fragments/icons/arrow_up_right.html",
        "fragments/icons/book.html",
        "fragments/icons/camera.html",
        "fragments/icons/check.html",
        "fragments/icons/copy.html",
        "fragments/icons/download.html",
        "fragments/icons/external.html",
        "fragments/icons/file.html",
        "fragments/icons/file_archive.html",
        "fragments/icons/file_image.html",
        "fragments/icons/file_text.html",
        "fragments/icons/fp_mark.html",
        "fragments/icons/link.html",
        "fragments/icons/more_h.html",
        "fragments/icons/plus.html",
        "fragments/icons/refresh.html",
        "fragments/icons/shield.html",
        "fragments/icons/tag.html",
        "fragments/icons/trash.html",
        "fragments/icons/x.html",
    );

    env.add_filter("strftime", |t: Serde<NaiveDateTime>, fmt: &str| {
        t.format(fmt).to_string()
    });

    #[derive(Deserialize)]
    struct CheckedAt {
        checked_at: Option<String>,
    }
    env.add_filter("checked_at_display", |v: Serde<CheckedAt>| {
        db::format_checked_at(&v.checked_at)
    });

    env.add_filter("latency_display", |b: Serde<db::BackendHealth>| {
        b.latency_display()
    });
    env.add_filter("http_code_display", |b: Serde<db::BackendHealth>| {
        b.http_code_display()
    });
    env.add_filter("port_display", |b: Serde<db::BackendHealth>| {
        b.port_display()
    });
    env.add_filter("latency_pct", |b: Serde<db::BackendHealth>, max: i64| {
        b.latency_pct(max)
    });
    env.add_filter("is_ok", |b: Serde<db::BackendHealth>| b.is_ok());
    env.add_filter("is_blocked", |b: Serde<db::BackendHealth>| b.is_blocked());
    env.add_filter("is_timeout", |b: Serde<db::BackendHealth>| b.is_timeout());
    env.add_filter("is_fallback", |b: Serde<db::BackendHealth>| b.is_fallback());

    env.add_filter("ok_count", |h: Serde<db::ProxyHealth>| h.ok_count());
    env.add_filter("total", |h: Serde<db::ProxyHealth>| h.total());
    env.add_filter("max_latency_ms", |h: Serde<db::ProxyHealth>| {
        h.max_latency_ms()
    });

    env.add_filter("size_display", |r: Serde<db::ResultRow>| r.size_display());
    env.add_filter("when_display", |r: Serde<db::ResultRow>| r.when_display());
    env.add_filter("is_completed", |r: Serde<db::ResultRow>| r.is_completed());
    env.add_filter("can_retry", |r: Serde<db::ResultRow>| r.can_retry());
    env.add_filter("has_retried", |r: Serde<db::ResultRow>| r.has_retried());
    env.add_filter("extractor_icon", |r: Serde<db::ResultRow>| {
        r.extractor_icon()
    });
    env.add_filter("extractor_desc", |r: Serde<db::ResultRow>| {
        r.extractor_desc()
    });

    env.add_filter(
        "effective_mime_type",
        |c: Serde<db::SnapshotUserContent>| c.effective_mime_type().to_string(),
    );
    env.add_filter(
        "minutes_until_expiry",
        |p: Serde<db::YoutubeOauthPending>| p.minutes_until_expiry(),
    );
    env
});

/// A page: its template and the context it renders with.
pub trait Page: Serialize {
    const TEMPLATE: &'static str;

    fn render(&self) -> Result<String, minijinja::Error> {
        ENV.get_template(Self::TEMPLATE)?.render(Serde(self))
    }
}

#[derive(Serialize)]
pub struct IndexTemplate {
    pub active: &'static str,
    pub stats: db::DashboardStats,
    pub snapshots: Vec<db::Snapshot>,
}

#[derive(Serialize)]
pub struct JobsListTemplate {
    pub active: &'static str,
    pub snapshots: Vec<db::Snapshot>,
    pub counts: db::StateCounts,
    pub filter: Option<String>,
    pub url_filter: String,
    pub tag_filter: String,
    pub run_filter: Option<i64>,
}

#[derive(Serialize)]
pub struct JobsNewTemplate {
    pub active: &'static str,
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct JobsManualTemplate {
    pub active: &'static str,
    pub error: Option<String>,
}

#[derive(Serialize)]
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

#[derive(Serialize)]
pub struct RunsListTemplate {
    pub active: &'static str,
    pub runs: Vec<db::Run>,
}

#[derive(Serialize)]
pub struct RunDetailTemplate {
    pub active: &'static str,
    pub run: Option<db::Run>,
    pub snapshots: Vec<db::Snapshot>,
    pub has_retriable: bool,
    pub has_active: bool,
}

#[derive(Serialize)]
pub struct ProxyStatusTemplate {
    pub active: &'static str,
    pub health: db::ProxyHealth,
}

#[derive(Serialize)]
pub struct NitterTemplate {
    pub active: &'static str,
    pub status: Option<db::NitterMintStatus>,
    pub override_row: Option<db::NitterCredsOverride>,
    pub trigger_path: String,
    pub egress: Option<db::ServiceEgressMode>,
}

#[derive(Serialize)]
pub struct YoutubeTemplate {
    pub active: &'static str,
    pub auth: Option<db::YoutubeCompanionAuth>,
    pub pending: Option<db::YoutubeOauthPending>,
    pub status: Option<db::YoutubeCompanionStatus>,
    pub egress_companion: Option<db::ServiceEgressMode>,
    pub egress_invidious: Option<db::ServiceEgressMode>,
}

#[derive(Serialize)]
pub struct LogsTemplate {
    pub active: &'static str,
}

#[derive(Serialize)]
pub struct HelpTemplate {
    pub active: &'static str,
}

#[derive(Serialize)]
pub struct JobTableFragment {
    pub snapshots: Vec<db::Snapshot>,
}

#[derive(Serialize)]
pub struct ProxyStatusFragment {
    pub health: db::ProxyHealth,
}

macro_rules! html_response {
    ($($t:ty => $name:literal),* $(,)?) => {$(
        impl Page for $t {
            const TEMPLATE: &'static str = $name;
        }

        impl axum::response::IntoResponse for $t {
            fn into_response(self) -> axum::response::Response {
                match self.render() {
                    Ok(body) => axum::response::Html(body).into_response(),
                    Err(err) => {
                        (axum::http::StatusCode::INTERNAL_SERVER_ERROR, err.to_string()).into_response()
                    }
                }
            }
        }
    )*};
}

html_response!(
    IndexTemplate => "index.html",
    JobsListTemplate => "jobs_list.html",
    JobsNewTemplate => "jobs_new.html",
    JobsManualTemplate => "jobs_manual.html",
    JobDetailTemplate => "job_detail.html",
    RunsListTemplate => "runs_list.html",
    RunDetailTemplate => "run_detail.html",
    ProxyStatusTemplate => "proxy_status.html",
    NitterTemplate => "nitter.html",
    YoutubeTemplate => "youtube.html",
    LogsTemplate => "logs.html",
    HelpTemplate => "help.html",
    JobTableFragment => "fragments/job_table.html",
    ProxyStatusFragment => "fragments/proxy_status.html",
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_parse_and_static_pages_render() {
        assert_eq!(ENV.templates().count(), 40);
        let logs = LogsTemplate { active: "logs" }.render().unwrap();
        assert!(logs.contains(r#"<a href="/logs" class="is-active">"#));
        assert!(
            HelpTemplate { active: "help" }
                .render()
                .unwrap()
                .contains("</html>")
        );
        let page = JobsNewTemplate {
            active: "jobs",
            error: Some("<b>bad</b>".into()),
        }
        .render()
        .unwrap();
        assert!(page.contains("&lt;b&gt;bad&lt;&#x2f;b&gt;"));
        let empty = JobTableFragment { snapshots: vec![] }.render().unwrap();
        assert!(empty.contains("No snapshots match these filters."));
    }
}
