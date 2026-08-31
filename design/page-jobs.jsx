// Jobs page — snapshots list with filters and segmented state filter.

const JOBS_DATA = [
  { id: 47, url: "https://news.ycombinator.com/item?id=43821044", state: "running",   tags: ["weekly","hn"], priority: 0, created: "2026-05-01 23:11:08", profile: "full" },
  { id: 46, url: "https://www.theverge.com/2026/4/30/anthropic-skills",  state: "running",   tags: ["news"],        priority: 1, created: "2026-05-01 23:10:54", profile: "full" },
  { id: 45, url: "https://twitter.example.com/elonmusk/status/1789203",  state: "completed", tags: ["twitter"],     priority: 0, created: "2026-05-01 22:48:12", profile: "compare" },
  { id: 44, url: "https://github.com/ArchiveTeam/grab-site",             state: "completed", tags: [],              priority: 0, created: "2026-05-01 22:30:01", profile: "full" },
  { id: 43, url: "https://reddit.example.com/r/programming/top/?t=week", state: "partial",   tags: ["reddit","weekly"], priority: 0, created: "2026-05-01 21:55:18", profile: "full" },
  { id: 42, url: "https://news.ycombinator.com/news",                    state: "completed", tags: ["hn","weekly"], priority: 0, created: "2026-05-01 21:00:00", profile: "lightweight" },
  { id: 41, url: "https://wikipedia.example.com/wiki/Hypertext",         state: "completed", tags: [],              priority: 0, created: "2026-05-01 20:42:33", profile: "full" },
  { id: 40, url: "https://example.com/notes/local-archive",              state: "failed",    tags: [],              priority: 0, created: "2026-05-01 20:11:03", profile: "full" },
  { id: 39, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",          state: "completed", tags: ["media"],       priority: 2, created: "2026-05-01 19:42:11", profile: "media" },
  { id: 38, url: "https://example.com",                                  state: "completed", tags: [],              priority: 0, created: "2026-04-28 20:56:11", profile: "full" },
  { id: 37, url: "https://example.com/this-is-a-very-long-url-with-utm-tracking-params?utm_source=email", state: "queued", tags: [], priority: 0, created: "2026-05-01 23:14:01", profile: "full" },
];

const STATE_TABS = [
  { id: "all",       label: "All",       count: 11 },
  { id: "queued",    label: "Queued",    count: 1  },
  { id: "running",   label: "Running",   count: 2  },
  { id: "completed", label: "Completed", count: 6  },
  { id: "partial",   label: "Partial",   count: 1  },
  { id: "failed",    label: "Failed",    count: 1  },
];

const Jobs = () => {
  const [active, setActive] = useState("all");
  const [urlQ, setUrlQ] = useState("");
  const [tagQ, setTagQ] = useState("");

  const visible = JOBS_DATA.filter(j => {
    if (active !== "all" && j.state !== active) return false;
    if (urlQ && !j.url.toLowerCase().includes(urlQ.toLowerCase())) return false;
    if (tagQ && !j.tags.some(t => t.toLowerCase().includes(tagQ.toLowerCase()))) return false;
    return true;
  });

  return (
    <div className="app jobs">
      <Appbar />
      <main className="jobs-main">
        <header className="jobs-hero">
          <div className="row gap-3" style={{ marginBottom: 8 }}>
            <span className="label">Archive queue</span>
          </div>
          <h1 className="jobs-hero__title">Snapshots</h1>
          <p className="jobs-hero__sub">
            Workers claim pending rows in priority order. State rolls up from per-extractor results — a snapshot is <em>partial</em> when at least one extractor failed but at least one succeeded.
          </p>
        </header>

        <div className="jobs-toolbar">
          <div className="jobs-tabs">
            {STATE_TABS.map(t => (
              <button
                key={t.id}
                className={`jobs-tab ${active === t.id ? "is-active" : ""}`}
                onClick={() => setActive(t.id)}
              >
                <span>{t.label}</span>
                <span className="jobs-tab__count">{t.count}</span>
              </button>
            ))}
          </div>
          <div className="jobs-toolbar__right">
            <button className="btn btn--primary btn--sm">
              <IconPlus size={14}/> New snapshot
            </button>
          </div>
        </div>

        <div className="jobs-filterbar">
          <div className="jobs-input">
            <span className="jobs-input__icon"><IconLink size={14}/></span>
            <input
              className="jobs-input__field"
              placeholder="URL contains…"
              value={urlQ}
              onChange={(e) => setUrlQ(e.target.value)}
            />
          </div>
          <div className="jobs-input">
            <span className="jobs-input__icon"><IconTag size={14}/></span>
            <input
              className="jobs-input__field"
              placeholder="Tag is…"
              value={tagQ}
              onChange={(e) => setTagQ(e.target.value)}
            />
          </div>
          <select className="select" defaultValue="any">
            <option value="any">Any profile</option>
            <option value="full">full</option>
            <option value="compare">compare</option>
            <option value="lightweight">lightweight</option>
            <option value="media">media</option>
          </select>
          <span className="muted sans" style={{ marginLeft: "auto", fontSize: 13 }}>
            {visible.length} of {JOBS_DATA.length} snapshots
          </span>
        </div>

        <div className="jobs-table-wrap">
          <table className="tbl jobs-table">
            <thead>
              <tr>
                <th style={{ width: 60 }}>ID</th>
                <th>URL</th>
                <th style={{ width: 130 }}>State</th>
                <th style={{ width: 200 }}>Tags</th>
                <th style={{ width: 80 }}>Profile</th>
                <th style={{ width: 56, textAlign: "center" }}>Pri</th>
                <th style={{ width: 170 }}>Created</th>
                <th style={{ width: 40 }}></th>
              </tr>
            </thead>
            <tbody>
              {visible.map(j => (
                <tr key={j.id} className="jobs-row">
                  <td className="mono muted">#{j.id}</td>
                  <td>
                    <a className="jobs-url mono" href="#">{j.url}</a>
                  </td>
                  <td><StatePillJobs state={j.state}/></td>
                  <td>
                    <div className="jobs-tags">
                      {j.tags.length === 0
                        ? <span className="muted">—</span>
                        : j.tags.map(t => <span key={t} className="jobs-tag">{t}</span>)}
                    </div>
                  </td>
                  <td className="mono jobs-profile">{j.profile}</td>
                  <td className="mono" style={{ textAlign: "center" }}>{j.priority}</td>
                  <td className="mono muted" style={{ fontSize: 12.5 }}>{j.created}</td>
                  <td>
                    <button className="btn btn--ghost btn--sm" aria-label="More">
                      <IconMoreH size={14}/>
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {visible.length === 0 && (
            <div className="jobs-empty">
              No snapshots match these filters.
            </div>
          )}
        </div>

        <footer className="jobs-foot">
          <span className="muted sans">Live — new snapshots appear as workers claim them.</span>
          <span className="flex-1"/>
          <a href="#" className="muted sans">View as JSON →</a>
        </footer>
      </main>
      <Statusbar />
    </div>
  );
};

const StatePillJobs = ({ state }) => {
  const map = {
    queued:    { cls: "pill--neutral", label: "queued"    },
    running:   { cls: "pill--info",    label: "running",   pulse: true },
    completed: { cls: "pill--success", label: "completed" },
    partial:   { cls: "pill--warning", label: "partial"   },
    failed:    { cls: "pill--danger",  label: "failed"    },
  };
  const { cls, label, pulse } = map[state] || map.queued;
  return (
    <span className={`pill ${cls}`}>
      <span className={`pill__dot ${pulse ? "pill__dot--pulse" : ""}`}/>
      {label}
    </span>
  );
};

window.Jobs = Jobs;
