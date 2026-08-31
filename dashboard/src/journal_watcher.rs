
use chrono::{Duration, Utc};
use regex::Regex;
use sqlx::PgPool;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub fn spawn(pool: PgPool) {
    if std::env::var("JOURNAL_WATCHER_DISABLE")
        .map(|v| !v.is_empty() && v != "0" && v != "false")
        .unwrap_or(false)
    {
        tracing::info!("journal_watcher: disabled via JOURNAL_WATCHER_DISABLE");
        return;
    }

    tokio::spawn(async move {
        let auth_pending = Regex::new(
            r"\[INFO\] \[OAUTH\] Go to (?P<url>\S+) in your browser and enter code (?P<code>\S+) to authenticate",
        )
        .expect("auth_pending regex compiles");
        let auth_success = Regex::new(r"\[INFO\] \[OAUTH\] Sign in successful!")
            .expect("auth_success regex compiles");
        let creds_updated = Regex::new(r"\[INFO\] \[OAUTH\] Credentials updated\.")
            .expect("creds_updated regex compiles");

        loop {
            tracing::info!("journal_watcher: starting journalctl tail for invidious-companion");
            if let Err(e) = run_once(&pool, &auth_pending, &auth_success, &creds_updated).await {
                tracing::warn!("journal_watcher: tail loop exited: {e:?}");
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    });
}

async fn run_once(
    pool: &PgPool,
    auth_pending: &Regex,
    auth_success: &Regex,
    creds_updated: &Regex,
) -> std::io::Result<()> {
    let mut child = Command::new("journalctl")
        .args([
            "-u",
            "invidious-companion.service",
            "--follow",
            "--no-pager",
            "--output=cat",
            "-n",
            "200",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;

    let stdout = child.stdout.take().expect("journalctl stdout piped");
    let reader = BufReader::new(stdout);
    let mut lines = reader.lines();

    while let Some(line) = lines.next_line().await? {
        if !line.contains("[OAUTH]") {
            continue;
        }

        if let Some(caps) = auth_pending.captures(&line) {
            let url = caps.name("url").map(|m| m.as_str()).unwrap_or("");
            let code = caps.name("code").map(|m| m.as_str()).unwrap_or("");
            let expires_at = Utc::now() + Duration::minutes(30);

            let _ = sqlx::query(
                "INSERT INTO youtube_oauth_pending
                    (id, device_code, user_code, verification_url,
                     interval_seconds, expires_at)
                 VALUES (1, '', $1, $2, 5, $3)
                 ON CONFLICT(id) DO UPDATE SET
                    user_code        = EXCLUDED.user_code,
                    verification_url = EXCLUDED.verification_url,
                    expires_at       = EXCLUDED.expires_at,
                    last_polled_at   = (now() AT TIME ZONE 'UTC'),
                    last_error       = NULL",
            )
            .bind(code)
            .bind(url)
            .bind(expires_at.naive_utc())
            .execute(pool)
            .await;
            tracing::info!(
                "journal_watcher: captured OAuth code {} → {}",
                code,
                url
            );
            continue;
        }

        if auth_success.is_match(&line) || creds_updated.is_match(&line) {
            let _ = sqlx::query("DELETE FROM youtube_oauth_pending WHERE id = 1")
                .execute(pool)
                .await;
            let _ = sqlx::query(
                "INSERT INTO youtube_companion_status
                    (id, po_token_ready, last_success_at, effective_method, updated_at)
                 VALUES (1, TRUE, (now() AT TIME ZONE 'UTC'), 'oauth', (now() AT TIME ZONE 'UTC'))
                 ON CONFLICT(id) DO UPDATE SET
                    po_token_ready    = TRUE,
                    last_success_at   = (now() AT TIME ZONE 'UTC'),
                    last_error        = NULL,
                    effective_method  = 'oauth',
                    updated_at        = (now() AT TIME ZONE 'UTC')",
            )
            .execute(pool)
            .await;
            tracing::info!("journal_watcher: OAuth sign-in successful");
        }
    }

    Ok(())
}
