// Help page — reference documentation, editorial layout with sticky TOC.

const Help = () => {
  const [activeSection, setActiveSection] = useState("overview");

  const TOC = [
    { id: "overview",  label: "Overview" },
    { id: "fronted",   label: "Fronted services" },
    { id: "proxy",     label: "Public proxy" },
    { id: "ui",        label: "Web UI" },
    { id: "extractors",label: "Extractors" },
    { id: "profiles",  label: "Profiles" },
    { id: "chains",    label: "Proxy chains" },
    { id: "api",       label: "JSON API" },
    { id: "shell",     label: "Shell access" },
    { id: "fs",        label: "Where things live" },
  ];

  return (
    <div className="app help">
      <Appbar />
      <main className="help-main">
        <header className="help-hero">
          <div className="row gap-3" style={{ marginBottom: 8 }}>
            <span className="label">Reference</span>
          </div>
          <h1 className="help-hero__title">Help</h1>
          <p className="help-hero__sub">
            Private social proxy and archive queue. All egress through Mullvad and Bright Data with per-chain failover. This page is the operator's reference — services, endpoints, extractors, proxy chains, and the JSON API.
          </p>
        </header>

        <div className="help-grid">
          <aside className="help-toc">
            <span className="label" style={{ display: "block", marginBottom: 12 }}>On this page</span>
            <nav className="help-toc__nav">
              {TOC.map(t => (
                <a
                  key={t.id}
                  href={`#${t.id}`}
                  className={`help-toc__link ${activeSection === t.id ? "is-active" : ""}`}
                  onClick={(e) => { e.preventDefault(); setActiveSection(t.id); }}
                >
                  {t.label}
                </a>
              ))}
            </nav>
            <div className="help-toc__meta">
              <a href="#" className="help-toc__metalink"><IconExternal size={12}/> openapi.json</a>
              <a href="#" className="help-toc__metalink"><IconShield size={12}/> Tailnet ACLs</a>
            </div>
          </aside>

          <article className="help-article">
            <section id="overview" className="help-section">
              <h2>Overview</h2>
              <p>
                Fetchproxies is a snapshot queue that runs your URL through ten parallel extractors and stores every artifact on disk under a stable ID. Every outbound HTTP request leaves through a chain of proxies — Mullvad rotation first, Bright Data as fallback — so the upstream sees a fresh egress and the host stays unidentified.
              </p>
            </section>

            <section id="fronted" className="help-section">
              <h2>Fronted services</h2>
              <p className="help-p--lead">
                URLs are transparent. <span className="mono">twitter.example.com/elonmusk</span> works the same way <span className="mono">twitter.com/elonmusk</span> does — same path, same query, just routed through a private frontend.
              </p>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead>
                    <tr><th style={{width:"22%"}}>Service</th><th style={{width:"30%"}}>vhost</th><th>Backend</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Twitter</td><td className="mono">twitter.example.com</td><td>nitter — cookie sessions minted via Bright Data scraping browser</td></tr>
                    <tr><td>Reddit</td><td className="mono">reddit.example.com</td><td>redlib — patched for <span className="mono">ALL_PROXY</span> rotation</td></tr>
                    <tr><td>Wikipedia</td><td className="mono">wikipedia.example.com</td><td>kiwix-serve — offline <span className="mono">.zim</span> corpus on <span className="mono">/persist/kiwix</span></td></tr>
                    <tr><td>Torrents</td><td className="mono">torrent.example.com</td><td>transmission — pinned to a single Mullvad tunnel (<span className="mono">100.64/24</span> only)</td></tr>
                    <tr><td>Archive UI</td><td className="mono">fetch.example.com</td><td>this dashboard</td></tr>
                    <tr><td>Artifacts</td><td className="mono">fetch.example.com/artifacts/results/&lt;id&gt;/</td><td>nginx autoindex over the host's results directory</td></tr>
                    <tr><td>Public proxy</td><td className="mono">proxy.example.com</td><td>SOCKS5 / HTTP / HTTPS forward proxy onto the archiver chain</td></tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section id="proxy" className="help-section">
              <h2>Public proxy <span className="help-h-mono">proxy.example.com</span></h2>
              <p>
                Use the host as a forward proxy from any tailnet host. All three flavours fan into the same in-guest archiver chain (Mullvad rotation → Bright Data fallback). Bound to <span className="mono">127.0.0.1</span> + the host's tailnet address (<span className="mono">100.x.y.z</span>) only — never publicly reachable.
              </p>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead><tr><th>Protocol</th><th>Endpoint</th><th>Notes</th></tr></thead>
                  <tbody>
                    <tr><td>SOCKS5</td><td className="mono">100.x.y.z:1080</td><td>plaintext over tailscale (already encrypted hop-by-hop)</td></tr>
                    <tr><td>HTTP forward</td><td className="mono">100.x.y.z:8118</td><td>handles <span className="mono">http://</span> and CONNECT-tunneled <span className="mono">https://</span></td></tr>
                    <tr><td>HTTPS forward</td><td className="mono">proxy.example.com:8443</td><td>TLS-terminated with the example.com wildcard cert</td></tr>
                    <tr><td>Browser GET</td><td className="mono">https://proxy.example.com/</td><td>302 → fetch.example.com (so a stray browser hit doesn't hang)</td></tr>
                  </tbody>
                </table>
              </div>

              <CodeBlock title="curl examples" lines={[
                { c: "# SOCKS5", k: "comment" },
                { c: "curl --socks5 100.x.y.z:1080 https://api.ipify.org" },
                { c: "" },
                { c: "# HTTP forward proxy (also tunnels HTTPS via CONNECT)", k: "comment" },
                { c: "curl -x http://100.x.y.z:8118 https://api.ipify.org" },
                { c: "" },
                { c: "# HTTPS forward proxy (TLS-wrapped)", k: "comment" },
                { c: "curl -x https://proxy.example.com:8443 https://api.ipify.org" },
              ]}/>
            </section>

            <section id="ui" className="help-section">
              <h2>Web UI</h2>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead><tr><th style={{width:"30%"}}>Page</th><th>What's there</th></tr></thead>
                  <tbody>
                    <tr><td className="mono">/</td><td>Overview — counts, recent snapshots, quick links</td></tr>
                    <tr><td className="mono">/jobs</td><td>Snapshots — filter by state, URL substring, tag</td></tr>
                    <tr><td className="mono">/jobs/new</td><td>Submit one or more URLs — pick profile, priority, tags, optional proxy override</td></tr>
                    <tr><td className="mono">/jobs/&lt;id&gt;</td><td>Per-snapshot detail — extractor table, retry/cancel/delete, re-archive, URL history</td></tr>
                    <tr><td className="mono">/runs</td><td>Runs — each user submission is one run; click in for run-wide retry/cancel/delete</td></tr>
                    <tr><td className="mono">/runs/&lt;id&gt;</td><td>Per-run detail — embedded snapshot table + bulk actions</td></tr>
                    <tr><td className="mono">/proxy</td><td>Per-backend health (status, latency, last checked)</td></tr>
                    <tr><td className="mono">/nitter</td><td>Nitter session mint status, force-trigger, dashboard credential override</td></tr>
                    <tr><td className="mono">/logs</td><td>journald SSE stream — autoscroll, pause, buffer stats</td></tr>
                    <tr><td className="mono">/proxy-log</td><td>squid <span className="mono">access.log</span> SSE</td></tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section id="extractors" className="help-section">
              <h2>Extractors</h2>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead><tr><th>Name</th><th>Tool</th><th>Output</th><th>Notes</th></tr></thead>
                  <tbody>
                    <tr><td className="mono">wget_warc</td><td className="mono">wget --warc</td><td><span className="mono">archive.warc.gz</span> + page-requisites</td><td>Full HTTP provenance</td></tr>
                    <tr><td className="mono">monolith</td><td className="mono">monolith</td><td><span className="mono">page.html</span> — assets inlined</td><td>Dropped <span className="mono">--proxy</span> in 2.10</td></tr>
                    <tr><td className="mono">screenshot</td><td className="mono">chromium --headless</td><td><span className="mono">screenshot.png</span> 1920×16384</td><td>Tall window approximates full-page</td></tr>
                    <tr><td className="mono">bd_screenshot</td><td>chromium → bright-data direct</td><td><span className="mono">screenshot.png</span></td><td>Side-by-side comparator</td></tr>
                    <tr><td className="mono">pdf</td><td className="mono">chromium --print-to-pdf</td><td><span className="mono">page.pdf</span></td><td>No header / footer</td></tr>
                    <tr><td className="mono">dom_dump</td><td className="mono">chromium --dump-dom</td><td><span className="mono">dom.html</span></td><td>JS executed</td></tr>
                    <tr><td className="mono">singlefile</td><td className="mono">single-file-cli</td><td><span className="mono">page.html</span></td><td>Self-contained</td></tr>
                    <tr><td className="mono">readability</td><td className="mono">readability-cli</td><td><span className="mono">readable.html</span></td><td>Article-mode extraction</td></tr>
                    <tr><td className="mono">yt_dlp</td><td className="mono">yt-dlp</td><td><span className="mono">data/&lt;title&gt;.&lt;ext&gt;</span></td><td>Video / audio</td></tr>
                    <tr><td className="mono">browsertrix</td><td>browsertrix-crawler</td><td>WACZ bundle</td><td>SPA-friendly</td></tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section id="profiles" className="help-section">
              <h2>Profiles</h2>
              <p>Pick one when submitting a snapshot — fans out into one row per extractor.</p>
              <ul className="help-profiles">
                <li><span className="mono help-prof-name">full</span><span className="muted sans">→</span><span className="mono">wget_warc, monolith, screenshot, readability, pdf</span></li>
                <li><span className="mono help-prof-name">compare</span><span className="muted sans">→</span><span className="mono">full + bd_screenshot</span> <span className="help-prof-note">mullvad-vs-bright-data side-by-side</span></li>
                <li><span className="mono help-prof-name">lightweight</span><span className="muted sans">→</span><span className="mono">monolith, readability</span></li>
                <li><span className="mono help-prof-name">media</span><span className="muted sans">→</span><span className="mono">yt_dlp</span></li>
                <li><span className="mono help-prof-name">warc_only</span><span className="muted sans">→</span><span className="mono">wget_warc</span></li>
                <li><span className="mono help-prof-name">bd_only</span><span className="muted sans">→</span><span className="mono">bd_screenshot</span></li>
              </ul>
            </section>

            <section id="chains" className="help-section">
              <h2>Proxy chains</h2>
              <p>
                Defined in <span className="mono">services.fetchproxies.proxy-chain.chains</span> (the host's <span className="mono">configuration.nix</span>). gost v3 with <span className="mono">strategy=fifo</span> — first backend wins, dead ones skipped for <span className="mono">failTimeout</span>.
              </p>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead><tr><th>Chain</th><th>Port</th><th>Backends (order = preference)</th></tr></thead>
                  <tbody>
                    <tr><td className="mono">nitter</td><td className="mono">1081</td><td className="mono">vpn-exit → mullvad-{`{de-dus,ch-zrh,at-vie,br-all,us-bos,us-mia}`}</td></tr>
                    <tr><td className="mono">redlib</td><td className="mono">1082</td><td className="mono">mullvad-us-{`{bos,mia,sjc}`} → mullvad-{`{de-dus,ch-zrh,at-vie}`}</td></tr>
                    <tr><td className="mono">archiver</td><td className="mono">1083</td><td className="mono">9× mullvad rotation, then bright-data fallback</td></tr>
                    <tr><td className="mono">brightdata-relay</td><td className="mono">10819</td><td className="mono">auth-injecting forward to brd.superproxy.io:44445</td></tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section id="api" className="help-section">
              <h2>JSON API</h2>
              <p>Full machine-readable spec at <a href="#" className="mono">/api/openapi.json</a>.</p>
              <div className="help-tbl-wrap">
                <table className="tbl help-tbl">
                  <thead><tr><th style={{width:80}}>Method</th><th style={{width:"35%"}}>Endpoint</th><th>Purpose</th></tr></thead>
                  <tbody>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/stats</td><td>Snapshot + artifact counts</td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/snapshots</td><td>Recent 100 (filter via <span className="mono">?state=</span>, <span className="mono">?url=</span>, <span className="mono">?tag=</span>)</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/v1/snapshots</td><td>Create one or many snapshots</td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/snapshots/&lt;id&gt;</td><td>One snapshot</td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/snapshots/&lt;id&gt;/results</td><td>Extractor rows</td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/snapshots/&lt;id&gt;/artifacts</td><td>Files written by completed extractors</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/snapshots/&lt;id&gt;/retry</td><td>Requeue every failed/skipped result</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/snapshots/&lt;id&gt;/cancel</td><td>Mark pending+running results skipped</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/snapshots/&lt;id&gt;/delete</td><td>Cascade-delete the row</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/snapshots/&lt;id&gt;/rearchive</td><td>New single-snapshot run with same URL/tags/extractors</td></tr>
                    <tr><td><span className="http http--post">POST</span></td><td className="mono">/api/results/&lt;id&gt;/retry</td><td>Requeue one extractor row</td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/proxy/health</td><td>Per-backend health from <span className="mono">proxy-probe</span></td></tr>
                    <tr><td><span className="http http--get">GET</span></td><td className="mono">/api/v1/export</td><td>Full JSON dump (runs + snapshots + results + artifacts)</td></tr>
                  </tbody>
                </table>
              </div>

              <CodeBlock title="Submit via curl" lines={[
                { c: "# single URL", k: "comment" },
                { c: "curl -sX POST https://fetch.example.com/api/v1/snapshots \\" },
                { c: "  -H 'content-type: application/json' \\" },
                { c: `  -d '{"url":"https://example.com","profile":"compare","tags":["sample"]}'` },
                { c: "" },
                { c: "# batch (one run, many snapshots)", k: "comment" },
                { c: "curl -sX POST https://fetch.example.com/api/v1/snapshots \\" },
                { c: "  -H 'content-type: application/json' \\" },
                { c: `  -d '{"urls":["https://a.com","https://b.com"],"profile":"full"}'` },
              ]}/>
            </section>

            <section id="shell" className="help-section">
              <h2>Shell access</h2>
              <CodeBlock lines={[
                { c: "# on the host, into the microvm", k: "comment" },
                { c: "ssh -p 2222 root@127.0.0.1" },
                { c: "" },
                { c: "# from anywhere on tailnet, into the host itself", k: "comment" },
                { c: "ssh <host>" },
              ]}/>
            </section>

            <section id="fs" className="help-section">
              <h2>Where things live</h2>
              <dl className="help-fs">
                <dt>db</dt>
                <dd><span className="mono">/var/lib/fetchproxies/db.sqlite</span> — WAL, snapshotted to <span className="mono">/srv/archive/db.sqlite.bak</span> every 5 min</dd>
                <dt>artifacts</dt>
                <dd><span className="mono">/srv/archive/results/&lt;result_id&gt;/</span> — the host's results share</dd>
                <dt>nitter sessions</dt>
                <dd><span className="mono">/srv/archive/config/nitter-sessions.jsonl</span></dd>
                <dt>health snapshot</dt>
                <dd><span className="mono">/srv/archive/config/proxy-health.json</span></dd>
                <dt>secrets staging</dt>
                <dd><span className="mono">/var/lib/fp-secrets/</span> — mullvad zips, bright-data env, twitter login env</dd>
              </dl>
            </section>
          </article>
        </div>
      </main>
      <Statusbar />
    </div>
  );
};

const CodeBlock = ({ title, lines }) => (
  <div className="codeblock">
    {title && (
      <div className="codeblock__head">
        <span className="codeblock__title">{title}</span>
        <button className="btn btn--ghost btn--sm"><IconCopy size={12}/></button>
      </div>
    )}
    <pre className="codeblock__pre"><code>
      {lines.map((l, i) => (
        <div key={i} className={`codeblock__line ${l.k === "comment" ? "is-comment" : ""}`}>
          {l.c || "\u00a0"}
        </div>
      ))}
    </code></pre>
  </div>
);

window.Help = Help;
