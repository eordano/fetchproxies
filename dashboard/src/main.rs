use axum::Router;
use axum::routing::{get, post};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::Duration;
use tower_http::services::ServeDir;

mod db;
mod journal_watcher;
mod routes;
mod supervisor;
mod templates;

pub struct AppState {
    pub db: sqlx::PgPool,
    pub proxy_health_path: String,
    pub nitter_trigger_path: String,
    pub public_url: Option<String>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let database_url =
        std::env::var("DATABASE_URL").expect("DATABASE_URL must be set (postgres URI)");

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await
        .expect("Failed to open postgres pool");

    let state = Arc::new(AppState {
        db: pool,
        proxy_health_path: std::env::var("PROXY_HEALTH_PATH")
            .unwrap_or_else(|_| "/srv/archive/config/proxy-health.json".to_string()),
        nitter_trigger_path: std::env::var("NITTER_MINT_TRIGGER")
            .unwrap_or_else(|_| "/var/lib/fetchproxies/nitter-mint.trigger".to_string()),
        public_url: std::env::var("PUBLIC_URL").ok().filter(|s| !s.is_empty()),
    });

    supervisor::regenerate_all(&state.db).await;

    journal_watcher::spawn(state.db.clone());

    let app = Router::new()
        .route("/", get(routes::index))
        .route("/jobs", get(routes::jobs_list))
        .route("/jobs/new", get(routes::jobs_new_form))
        .route("/jobs/manual", get(routes::jobs_manual_form))
        .route("/jobs/{id}", get(routes::job_detail))
        .route("/runs", get(routes::runs_list))
        .route("/runs/{id}", get(routes::run_detail))
        .route("/proxy", get(routes::proxy_status))
        .route("/nitter", get(routes::nitter_page))
        .route("/youtube", get(routes::youtube_page))
        .route("/logs", get(routes::logs_page))
        .route("/logs/stream", get(routes::logs_stream))
        .route("/proxy-log", get(routes::proxy_log_page))
        .route("/proxy-log/stream", get(routes::proxy_log_stream))
        .route("/help", get(routes::help_page))
        .route("/api/jobs", post(routes::api_create_jobs_batch))
        .route("/api/jobs/manual", post(routes::api_create_manual_snapshot))
        .route(
            "/api/snapshots/{id}/retry",
            post(routes::api_retry_snapshot),
        )
        .route(
            "/api/snapshots/{id}/cancel",
            post(routes::api_cancel_snapshot),
        )
        .route(
            "/api/snapshots/{id}/delete",
            post(routes::api_delete_snapshot),
        )
        .route(
            "/api/snapshots/{id}/rearchive",
            post(routes::api_rearchive_snapshot),
        )
        .route("/api/results/{id}/retry", post(routes::api_retry_result))
        .route("/api/results/{id}/markdown", get(routes::api_result_markdown))
        .route("/api/runs/{id}/retry", post(routes::api_retry_run))
        .route("/api/runs/{id}/cancel", post(routes::api_cancel_run))
        .route("/api/runs/{id}/delete", post(routes::api_delete_run))
        .route("/api/nitter/trigger", post(routes::api_nitter_trigger))
        .route("/api/nitter/override", post(routes::api_nitter_override))
        .route(
            "/api/services/{service}/egress",
            post(routes::api_set_egress),
        )
        .route(
            "/api/youtube/oauth/start",
            post(routes::api_youtube_oauth_start),
        )
        .route(
            "/api/youtube/oauth/manual",
            post(routes::api_youtube_oauth_manual),
        )
        .route("/api/youtube/cookies", post(routes::api_youtube_cookies))
        .route("/api/youtube/auth/clear", post(routes::api_youtube_clear))
        .route("/api/openapi.json", get(routes::openapi_spec))
        .route("/api/v1/stats", get(routes::api_json_stats))
        .route("/api/v1/proxy/health", get(routes::api_json_proxy_health))
        .route(
            "/api/v1/snapshots",
            get(routes::api_json_snapshots).post(routes::api_json_create_snapshot),
        )
        .route(
            "/api/v1/snapshots/manual",
            post(routes::api_json_create_manual_snapshot),
        )
        .route("/api/v1/snapshots/{id}", get(routes::api_json_snapshot))
        .route(
            "/api/v1/snapshots/{id}/results",
            get(routes::api_json_snapshot_results),
        )
        .route(
            "/api/v1/snapshots/{id}/artifacts",
            get(routes::api_json_snapshot_artifacts),
        )
        .route(
            "/api/v1/snapshots/{id}/markdown",
            get(routes::api_json_snapshot_markdown),
        )
        .route("/api/v1/markdown", get(routes::api_json_markdown_lookup))
        .route(
            "/api/v1/results/{id}/markdown",
            get(routes::api_result_markdown),
        )
        .route("/api/v1/runs", get(routes::api_json_runs))
        .route("/api/v1/runs/{id}", get(routes::api_json_run))
        .route("/api/v1/profiles", get(routes::api_json_profiles))
        .route("/api/v1/export", get(routes::api_export))
        .route(
            "/api/v1/import/snapshots",
            post(routes::api_import_snapshots),
        )
        .route("/fragments/job-table", get(routes::fragment_job_table))
        .route(
            "/fragments/proxy-status",
            get(routes::fragment_proxy_status),
        )
        .with_state(state)
        .nest_service(
            "/static",
            ServeDir::new(
                std::env::var("DASHBOARD_STATIC_DIR")
                    .unwrap_or_else(|_| "/etc/fetchproxies-dashboard/static".to_string()),
            ),
        );

    let port: u16 = std::env::var("DASHBOARD_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8080);
    let addr = format!("0.0.0.0:{}", port);
    tracing::info!("Dashboard listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
