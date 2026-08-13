// Logs page — live SSE stream

const LOG_LINES = [
  { t: "20:13:41", unit: "MULLVAD-RELAY-US-SJC", proto: "socks5", from: "127.0.0.1:43332", op: ">—<", to: "www.reddit.com:443" },
  { t: "20:13:41", unit: "MULLVAD-RELAY-US-SJC", proto: "socks5", from: "127.0.0.1:43332", op: "><",  to: "127.0.0.1:10818" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-DE-DUS", proto: "socks5", from: "127.0.0.1:56938", op: ">—<", to: "oauth.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-DE-DUS", proto: "socks5", from: "127.0.0.1:56938", op: "><",  to: "127.0.0.1:10815" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-DE-DUS", proto: "socks5", from: "127.0.0.1:52788", op: ">—<", to: "www.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-DE-DUS", proto: "socks5", from: "127.0.0.1:52788", op: "><",  to: "127.0.0.1:10815" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-CH-ZRH", proto: "socks5", from: "127.0.0.1:45752", op: ">—<", to: "www.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-CH-ZRH", proto: "socks5", from: "127.0.0.1:45752", op: "><",  to: "127.0.0.1:10813" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-CH-ZRH", proto: "socks5", from: "127.0.0.1:44490", op: ">—<", to: "oauth.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-CH-ZRH", proto: "socks5", from: "127.0.0.1:44490", op: "><",  to: "127.0.0.1:10813" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-AT-VIE", proto: "socks5", from: "127.0.0.1:45914", op: ">—<", to: "www.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-AT-VIE", proto: "socks5", from: "127.0.0.1:45914", op: "><",  to: "127.0.0.1:10811" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-AT-VIE", proto: "socks5", from: "127.0.0.1:38912", op: ">—<", to: "oauth.reddit.com:443" },
  { t: "20:13:42", unit: "MULLVAD-RELAY-AT-VIE", proto: "socks5", from: "127.0.0.1:38912", op: "><",  to: "127.0.0.1:10811" },
  { t: "20:13:43", unit: "FETCHPROXIES-WORKER-3", proto: "task",  from: "snapshot#47",     op: ":",   to: "claimed extractor=monolith pri=0", level: "info" },
  { t: "20:13:43", unit: "MONOLITH",              proto: "exec",  from: "snapshot#47",     op: ":",   to: "fetching https://news.ycombinator.com/item?id=43821044", level: "info" },
  { t: "20:13:44", unit: "PROXY-PROBE",           proto: "warn",  from: "ar-bue",          op: ":",   to: "stale (last_checked > 24h)", level: "warn" },
  { t: "20:13:45", unit: "FETCHPROXIES-WORKER-1", proto: "task",  from: "snapshot#46",     op: ":",   to: "extractor=screenshot done in 3.4s, 412 KB", level: "ok" },
];

const unitColor = (u) => {
  if (u.startsWith("MULLVAD")) return "mullvad";
  if (u.startsWith("FETCHPROXIES")) return "worker";
  if (u === "MONOLITH") return "monolith";
  if (u === "PROXY-PROBE") return "probe";
  return "default";
};

const Logs = () => {
  const [autoscroll, setAutoscroll] = useState(true);
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState("");
  const [received] = useState(74);

  const filtered = LOG_LINES.filter(l =>
    !filter ||
    l.unit.toLowerCase().includes(filter.toLowerCase()) ||
    l.to.toLowerCase().includes(filter.toLowerCase()) ||
    l.from.toLowerCase().includes(filter.toLowerCase())
  );

  return (
    <div className="app logs">
      <Appbar />
      <main className="logs-main">
        <header className="logs-hero">
          <div className="row gap-3" style={{ marginBottom: 8 }}>
            <span className="label">Live stream</span>
            <span className={`logs-pulse ${paused ? "is-paused" : ""}`}>
              <span className="logs-pulse__dot"/>
              <span className="mono">{paused ? "paused" : "streaming"}</span>
            </span>
          </div>
          <h1 className="logs-hero__title">Live logs</h1>
          <p className="logs-hero__sub">
            All fetchproxies-related systemd units — dashboard, workers, schema/restore, frontends (nitter, redlib, kiwix, invidious, transmission), proxy chains, mullvad relays, brightdata relay, http→socks bridges, podman containers. Parsed from <span className="mono">journalctl -o json --follow</span>.
          </p>
        </header>

        <div className="logs-toolbar">
          <button
            className={`logs-toggle ${autoscroll ? "is-on" : ""}`}
            onClick={() => setAutoscroll(!autoscroll)}
          >
            <span className="logs-check">{autoscroll && <IconCheck size={11}/>}</span>
            Autoscroll
          </button>
          <button
            className={`logs-toggle ${paused ? "is-on" : ""}`}
            onClick={() => setPaused(!paused)}
          >
            <span className="logs-check">{paused && <IconCheck size={11}/>}</span>
            Pause
          </button>
          <button className="btn btn--ghost btn--sm">
            <IconX size={13}/> Clear
          </button>
          <div className="jobs-input" style={{ flex: 1, maxWidth: 320 }}>
            <span className="jobs-input__icon"><IconActivity size={13}/></span>
            <input
              className="jobs-input__field"
              placeholder="Filter (substring of unit or message)…"
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
            />
          </div>
          <span className="flex-1"/>
          <span className="muted sans" style={{ fontSize: 13 }}>
            received <span className="mono">{received}</span> · buffer <span className="mono">2 MB</span>
          </span>
        </div>

        <div className="logs-stream">
          {filtered.map((l, i) => (
            <div key={i} className={`logs-row logs-row--${l.level || "trace"}`}>
              <span className="logs-time mono">{l.t}</span>
              <span className={`logs-unit logs-unit--${unitColor(l.unit)}`}>{l.unit}</span>
              <span className="logs-proto mono">{l.proto}</span>
              <span className="logs-msg mono">
                <span className="logs-msg__from">{l.from}</span>
                <span className="logs-msg__op">{l.op}</span>
                <span className="logs-msg__to">{l.to}</span>
              </span>
            </div>
          ))}
          <div className="logs-row logs-row--ghost">
            <span className="logs-cursor"/>
          </div>
        </div>
      </main>
      <Statusbar />
    </div>
  );
};

window.Logs = Logs;
