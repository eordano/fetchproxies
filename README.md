# fetchproxies

A self-hosted fetch/archive proxy stack for NixOS: archive arbitrary web pages
in multiple formats, host privacy frontends (Nitter, Redlib, Invidious,
Kiwix), and route all egress through a rotating Mullvad WireGuard / Tor /
Bright Data proxy chain with a default-drop nftables kill-switch.

Designed to run inside a qemu microVM (user-mode networking) on a NixOS host,
with extractors sandboxed in ephemeral rootless-podman containers under gVisor.

## Layout

| Path | What |
|---|---|
| `default.nix` | NixOS module entry point; imports everything under `nix/` |
| `nix/` | NixOS modules, worker scripts, DB schema |
| `dashboard/` | Rust (axum + htmx + Askama) operator dashboard crate |
| `dashboard/dev/` | Laptop preview harness (seed data, fake journald feed) |
| `design/` | No-build-step browser canvas for the dashboard UI (React via CDN, vendored by `design/fetch-vendor.sh`) |
| `brightdata_proxy_ca.zip` | Bright Data's published certificate bundle, downloaded from `https://brightdata.com/static/brightdata_proxy_ca.zip` |
| `brightdata-ca.crt` | `brightdata_root_ca_44445.crt` extracted from that bundle for native proxy port 44445 |

## Components (`nix/`)

| Module | Role |
|---|---|
| `proxy-chain.nix` | SOCKS5 fabric (gost v3, fifo strategy) + default-drop nftables egress kill-switch |
| `mullvad-backend.nix` | Mullvad location zips -> `wg-<name>` WireGuard exits + per-exit SOCKS relays |
| `proxy-probe.nix` | Periodic backend health snapshot |
| `archiver.nix` | Postgres-backed work queue + gVisor worker fleet (`worker.sh`, `worker-image.nix`) |
| `dashboard.nix`, `dashboard-package.nix` | The Rust dashboard as a service / package |
| `nitter.nix`, `nitter-mint.nix` | Nitter frontend + automated Twitter session-cookie minting |
| `redlib.nix`, `invidious.nix`, `kiwix.nix` | Reddit / YouTube / offline-Wikipedia frontends |
| `firecrawl-vm.nix` | Firecrawl crawler |
| `transmission-vpn.nix` | Torrent daemon pinned to one Mullvad exit |
| `vm.nix`, `vm-configuration.nix` | microVM wiring and an example guest parameterisation |
| `schema.sql` | Postgres schema (Run -> Snapshot -> ArchiveResult -> Artifact) |
| `submit-job.sh` | CLI job submission against the dashboard API |

## Archive formats

WARC, self-contained `monolith` HTML, PDF, full-page screenshots at several
viewport widths, readability text, SingleFile, DOM dumps, `yt-dlp` media.

## Building

| Target | Command |
|---|---|
| Dashboard (cargo) | `cd dashboard && cargo build --release` |
| Dashboard (nix) | build `nix/dashboard-package.nix` with `pkgs.callPackage` |
| Whole stack | import `default.nix` into a NixOS configuration; see `nix/vm-configuration.nix` for a full example |
| Dashboard preview | `dashboard/dev/preview.sh` (seeded data, fake journal, no fleet needed) |
| Design canvas | `design/fetch-vendor.sh` then open `design/preview.html` |

Some modules take a `colmenaBasePath` argument and import host-side helper
modules (secrets staging, log forwarding, a shared `wireguard-per-uid-exits`
module) from the surrounding deployment repository; adapt those imports to
your own tree.

Secrets (Mullvad config zips, Bright Data credentials, DB/S3 env files,
Nitter login) are expected at `/var/lib/fp-secrets/`, staged read-only into
the VM via virtiofs -- nothing secret lives in this repository.

## Security

The dashboard has **no authentication**: anyone who can reach it can dump the
full archive database via `/api/v1/export`, control services, and write stored
credentials (Nitter login, YouTube OAuth tokens) through the API. It is
intended for a trusted/LAN or tailnet-only deployment; do not expose it to the
public internet.

## License

MIT, see [LICENSE](LICENSE).
