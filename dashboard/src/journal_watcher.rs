// Tail invidious-companion's journal and surface OAuth state in the DB.
//
// When the operator enables OAuth on /youtube, the supervisor flips
// YOUTUBE_SESSION_OAUTH_ENABLED=true in companion-overrides.env, the
// path unit restarts companion, and companion boots into the
// youtubei.js OAuth device flow. Companion's main.ts emits these
// exact lines (see invidious-companion@d5504eb src/main.ts:138-142):
//
//   [INFO] [OAUTH] Go to <verification_url> in your browser and enter
//                  code <user_code> to authenticate.
//   [INFO] [OAUTH] Sign in successful!
//   [INFO] [OAUTH] Credentials updated.
//
// We tail journalctl, regex those three patterns, and write through
// to youtube_oauth_pending / youtube_companion_status. The dashboard
// page reads from those tables — no Google API plumbing on our side,
// no shared OAuth client credentials, no extra egress: companion is
// already wired up to Google through the proxy chain (and once the
// operator has signed in, it switches to direct via the egress
// dropdown).
//
// The watcher restarts itself on journalctl exit. journalctl --follow
// blocks indefinitely, so the inner loop only exits if the child dies
// (kernel rotation, unit re-mask, etc.) — outer loop sleeps briefly
// and respawns.

use chrono::{Duration, Utc};
use regex::Regex;
use sqlx::PgPool;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub fn spawn(pool: PgPool) {
    // Skip the watcher entirely when the operator opts out — used by
    // dev/preview.sh, which has no invidious-companion unit on the
    // host and would otherwise spin spawning journalctl in a tight
    // retry loop.
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
        // Cheap fast-path: only inspect lines tagged as OAuth.
        if !line.contains("[OAUTH]") {
            continue;
        }

        if let Some(caps) = auth_pending.captures(&line) {
            // youtubei.js's device-flow expiry is 30 min for the TV
            // client. We don't get an explicit ttl on the event, so
            // estimate conservatively — the row gets cleared either
            // when companion logs success or when the operator hits
            // the cancel button on the page.
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
            // Either path means companion now has a valid session.
            // Clear the in-flight row + mark status as ready. We
            // don't have the refresh_token here (companion stashes
            // it in its own Deno KV cache); auth_method stays
            // 'oauth' so the supervisor keeps emitting
            // YOUTUBE_SESSION_OAUTH_ENABLED=true on next restart and
            // companion picks up the cached creds without bothering
            // the user again.
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
