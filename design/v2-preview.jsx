// V2 — Split detail with screenshot preview.
// The screenshot extractor produced an image — surface it.
// Two-column: preview + facts/actions on the left, extractor table on the right.

const V2 = () => {
  const s = SNAPSHOT;

  return (
    <div className="app v2">
      <Appbar />
      <main className="v2-main">
        <div className="v2-crumbs">
          <a href="#">all snapshots</a>
          <span className="crumbs__sep">›</span>
          <a href="#">run #{s.runId}</a>
          <span className="crumbs__sep">›</span>
          <span>snapshot #{s.id}</span>
        </div>

        <header className="v2-hero">
          <div className="row gap-3" style={{ marginBottom: 8 }}>
            <span className="label">Snapshot #{s.id}</span>
            <StatusPill state={s.status} />
          </div>
          <h1 className="v2-hero__title">{s.title}</h1>
          <a className="v2-hero__url mono" href={s.url}>{s.url} <IconArrowUpRight size={14}/></a>
        </header>

        <div className="v2-grid">
          {/* LEFT: preview + facts + actions */}
          <aside className="v2-left">
            <figure className="v2-preview">
              <div className="v2-preview__chrome">
                <span className="v2-preview__dot"/>
                <span className="v2-preview__dot"/>
                <span className="v2-preview__dot"/>
                <span className="v2-preview__addr mono">{s.hostname}</span>
              </div>
              <div className="v2-preview__img">
                <div className="v2-preview__page">
                  <div className="v2-preview__page-hdr"/>
                  <div className="v2-preview__page-h"/>
                  <div className="v2-preview__page-l" style={{ width: "92%" }}/>
                  <div className="v2-preview__page-l" style={{ width: "84%" }}/>
                  <div className="v2-preview__page-l" style={{ width: "70%" }}/>
                  <div className="v2-preview__page-h2" style={{ marginTop: 22 }}/>
                  <div className="v2-preview__page-l" style={{ width: "88%" }}/>
                  <div className="v2-preview__page-l" style={{ width: "76%" }}/>
                  <div className="v2-preview__page-img"/>
                </div>
              </div>
              <figcaption className="v2-preview__cap muted sans">
                screenshot.png · 363.0 KB
              </figcaption>
            </figure>

            <div className="v2-facts">
              <dl className="keyfacts">
                <dt>Priority</dt>
                <dd className="mono">{s.priority}</dd>
                <dt>Tags</dt>
                <dd className="muted">no tags</dd>
                <dt>Created</dt>
                <dd className="mono">{s.createdAt}</dd>
                <dt>Updated</dt>
                <dd className="mono">{s.updatedAt}</dd>
                <dt>Duration</dt>
                <dd className="mono">{s.durationSec}.0 s</dd>
                <dt>Total</dt>
                <dd className="mono">{s.totalSize}</dd>
              </dl>
            </div>

            <div className="v2-actions card">
              <div className="v2-actions__row">
                <button className="btn btn--primary v2-actions__re">
                  <IconRefresh size={14}/> Re-archive
                </button>
                <select className="select" defaultValue="same">
                  <option value="same">same extractors</option>
                  <option value="all">all extractors</option>
                  <option value="failed">only failed</option>
                </select>
              </div>
              <div className="v2-actions__row">
                <button className="btn flex-1">
                  <IconExternal size={14}/> Open original
                </button>
                <button className="btn btn--danger flex-1">
                  <IconTrash size={14}/> Delete
                </button>
              </div>
            </div>
          </aside>

          {/* RIGHT: extractor results */}
          <section className="v2-right">
            <header className="v2-section-head">
              <div>
                <h2 className="v2-section-head__title">Extractor results</h2>
                <p className="muted sans" style={{ fontSize: 13 }}>5 of 5 completed · captured in 8.0 s</p>
              </div>
              <button className="btn btn--ghost btn--sm">
                <IconDownload size={14}/> download all
              </button>
            </header>

            <ul className="v2-extractors">
              {s.extractors.map(e => (
                <li key={e.id} className="v2-extractor">
                  <span className="v2-extractor__icon"><ExtractorIcon name={e.icon} size={18}/></span>
                  <div className="v2-extractor__main">
                    <div className="v2-extractor__line">
                      <span className="mono v2-extractor__name">{e.label}</span>
                      <span className="muted sans v2-extractor__desc">{e.desc}</span>
                    </div>
                    <div className="v2-extractor__meta">
                      <StatusPill state={e.state}/>
                      <span className="muted sans">·</span>
                      <span className="mono muted">{e.size}</span>
                      <span className="muted sans">·</span>
                      <span className="mono muted" style={{ fontSize: 12 }}>{e.when}</span>
                      {e.retries > 0 && (<><span className="muted sans">·</span><span className="muted sans">{e.retries} retries</span></>)}
                    </div>
                  </div>
                  <a href="#" className="v2-extractor__dl">
                    <IconDownload size={14}/> download
                  </a>
                </li>
              ))}
            </ul>

            <div className="v2-history">
              <header className="v2-section-head">
                <div>
                  <h2 className="v2-section-head__title">URL history</h2>
                  <p className="muted sans" style={{ fontSize: 13 }}>Earlier captures of this URL</p>
                </div>
              </header>
              <div className="v2-history__row">
                <div className="v2-history__bullet"/>
                <div className="v2-history__main">
                  <div className="row gap-3">
                    <span className="mono">2026-04-28 20:56</span>
                    <StatusPill state="completed"/>
                    <span className="muted sans">this snapshot</span>
                  </div>
                </div>
                <span className="mono muted">5.0 MB</span>
              </div>
              <p className="muted sans" style={{ fontSize: 13, marginTop: 12 }}>
                No other archives of this URL. Click <em>Re-archive</em> above to capture a fresh snapshot.
              </p>
            </div>
          </section>
        </div>
      </main>
      <Statusbar />
    </div>
  );
};

window.V2 = V2;
