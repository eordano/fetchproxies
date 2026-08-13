// Proxy page — chain status
const PROXY_DATA = [
  { backend: "us-sjc", port: 10818, status: "ok",   http: 200, latency: 1146, checked: "2026-04-28 01:40:21" },
  { backend: "br-all", port: 10812, status: "ok",   http: 200, latency: 1337, checked: "2026-04-28 01:40:21" },
  { backend: "us-mia", port: 10817, status: "ok",   http: 200, latency: 1378, checked: "2026-04-28 01:40:21" },
  { backend: "at-vie", port: 10811, status: "ok",   http: 200, latency: 1505, checked: "2026-04-28 01:40:21" },
  { backend: "ar-bue", port: 10810, status: "warn", http: 200, latency: 1523, checked: "2026-04-30 19:19:06" },
  { backend: "de-dus", port: 10815, status: "ok",   http: 200, latency: 1538, checked: "2026-04-28 01:40:21" },
  { backend: "us-bos", port: 10816, status: "ok",   http: 200, latency: 1584, checked: "2026-04-28 01:40:21" },
  { backend: "co-bog", port: 10814, status: "ok",   http: 200, latency: 1728, checked: "2026-04-28 01:40:21" },
  { backend: "ch-zrh", port: 10813, status: "ok",   http: 200, latency: 1867, checked: "2026-04-28 01:40:21" },
  { backend: "brightdata", port: 10819, status: "ok", http: 200, latency: 412, checked: "2026-05-01 23:11:28", isFallback: true },
];

const Proxy = () => {
  const probed = "2026-05-01 23:11:28";
  const maxLatency = Math.max(...PROXY_DATA.map(d => d.latency));
  const okCount = PROXY_DATA.filter(p => p.status === "ok").length;

  return (
    <div className="app proxy">
      <Appbar />
      <main className="proxy-main">
        <header className="proxy-hero">
          <div className="row gap-3" style={{ marginBottom: 8 }}>
            <span className="label">Health</span>
          </div>
          <h1 className="proxy-hero__title">Proxy chain status</h1>
          <p className="proxy-hero__sub">
            Per-backend health from <span className="mono">/srv/archive/config/proxy-health.json</span>, refreshed by the <span className="mono">proxy-probe</span> timer (~hourly) and live-updated here every 10s.
          </p>
        </header>

        <div className="proxy-summary">
          <div className="proxy-stat">
            <span className="label">Online</span>
            <strong className="proxy-stat__num">{okCount}<span className="muted">/{PROXY_DATA.length}</span></strong>
            <span className="muted sans" style={{ fontSize: 12 }}>backends responding</span>
          </div>
          <div className="proxy-stat">
            <span className="label">Last probe</span>
            <strong className="proxy-stat__num mono" style={{ fontSize: 18, fontWeight: 500 }}>{probed}</strong>
            <span className="muted sans" style={{ fontSize: 12 }}>via <span className="mono">/r/programming</span></span>
          </div>
          <div className="proxy-stat">
            <span className="label">Active chain</span>
            <strong className="proxy-stat__chain mono">
              archiver <IconArrowRight size={12}/> us-sjc <IconArrowRight size={12}/> exit
            </strong>
            <span className="muted sans" style={{ fontSize: 12 }}>9× mullvad rotation, then bright-data</span>
          </div>
        </div>

        <div className="proxy-table-wrap">
          <table className="tbl proxy-table">
            <thead>
              <tr>
                <th style={{ width: 140 }}>Backend</th>
                <th style={{ width: 90 }}>Port</th>
                <th style={{ width: 110 }}>Status</th>
                <th style={{ width: 70 }}>HTTP</th>
                <th>Latency</th>
                <th style={{ width: 170 }}>Last checked</th>
              </tr>
            </thead>
            <tbody>
              {PROXY_DATA.map(p => (
                <tr key={p.backend}>
                  <td>
                    <div className="row gap-2">
                      <span className="mono proxy-backend">{p.backend}</span>
                      {p.isFallback && <span className="proxy-fallback">fallback</span>}
                    </div>
                  </td>
                  <td className="mono muted">{p.port}</td>
                  <td>
                    {p.status === "ok"
                      ? <span className="pill pill--success"><span className="pill__dot"/>ok</span>
                      : <span className="pill pill--warning"><span className="pill__dot"/>stale</span>}
                  </td>
                  <td className="mono">{p.http}</td>
                  <td>
                    <div className="proxy-lat">
                      <div className="proxy-lat__bar">
                        <span className="proxy-lat__fill" style={{ width: `${(p.latency / maxLatency) * 100}%` }}/>
                      </div>
                      <span className="mono proxy-lat__num">{p.latency} ms</span>
                    </div>
                  </td>
                  <td className="mono muted" style={{ fontSize: 12.5 }}>{p.checked}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </main>
      <Statusbar />
    </div>
  );
};

window.Proxy = Proxy;
