// Shared data + chrome used by all variations.

const { useState, useEffect } = React;

const SNAPSHOT = {
  id: 1,
  runId: 1,
  url: "https://eordano.com",
  hostname: "eordano.com",
  title: "Martín Eordano — Notes & writing",
  priority: 0,
  tags: [],
  createdAt: "2026-04-28 20:56:11",
  updatedAt: "2026-04-28 20:56:19",
  durationSec: 8,
  status: "completed",
  totalSize: "5.0 MB",
  extractors: [
    { id: "monolith",   label: "monolith",   desc: "Single-file HTML",        size: "1002.2 KB", state: "completed", retries: 0, when: "2026-04-28 20:56:18", icon: "FileArchive" },
    { id: "pdf",        label: "pdf",        desc: "Print-to-PDF",            size: "2.2 MB",   state: "completed", retries: 0, when: "2026-04-28 20:56:19", icon: "FileText" },
    { id: "readability",label: "readability",desc: "Article body, plain",     size: "3.5 KB",   state: "completed", retries: 0, when: "2026-04-28 20:56:14", icon: "Book" },
    { id: "screenshot", label: "screenshot", desc: "Full-page PNG",           size: "363.0 KB", state: "completed", retries: 0, when: "2026-04-28 20:56:18", icon: "Camera" },
    { id: "wget_warc",  label: "wget_warc",  desc: "WARC bundle",             size: "1.3 MB",   state: "completed", retries: 0, when: "2026-04-28 20:56:18", icon: "FileArchive" },
  ],
  proxyChain: ["openapi", "export", "socks", "mullvad", "exit"],
};

const NAV_ITEMS = [
  { id: "jobs",     label: "jobs" },
  { id: "runs",     label: "runs", active: true },
  { id: "proxy",    label: "proxy" },
  { id: "nitter",   label: "nitter" },
  { id: "youtube",  label: "youtube" },
  { id: "logs",     label: "logs" },
  { id: "proxylog", label: "proxy log" },
  { id: "help",     label: "help" },
];

const Appbar = ({ onAction }) => (
  <header className="appbar">
    <a className="appbar__brand" href="#">
      <span className="appbar__brand-mark"><FpMark size={22} /></span>
      <span>fetchproxies</span>
    </a>
    <nav className="appbar__nav">
      {NAV_ITEMS.map(n => (
        <a
          key={n.id}
          href="#"
          className={n.active ? "is-active" : ""}
          onClick={(e) => e.preventDefault()}
        >{n.label}</a>
      ))}
    </nav>
    <div className="appbar__right">
      <button className="btn btn--primary btn--sm" onClick={onAction}>
        <IconPlus size={14} /> new snapshot
      </button>
    </div>
  </header>
);

const Statusbar = () => (
  <footer className="statusbar">
    <span className="statusbar__chain">
      <span className="statusbar__dot" />
      <span>openapi</span>
      <span className="statusbar__sep">·</span>
      <span>export</span>
      <span className="statusbar__sep">·</span>
      <span>socks</span>
      <span className="statusbar__sep">→</span>
      <span>mullvad</span>
      <span className="statusbar__sep">→</span>
      <span>exit</span>
    </span>
    <span className="flex-1" />
    <span className="muted">connected · 4 ms</span>
  </footer>
);

// Generic status pill
const StatusPill = ({ state, size }) => {
  const map = {
    completed: { cls: "pill--success", label: "completed" },
    running:   { cls: "pill--info",    label: "running"   },
    queued:    { cls: "pill--neutral", label: "queued"    },
    failed:    { cls: "pill--danger",  label: "failed"    },
  };
  const { cls, label } = map[state] || map.completed;
  return (
    <span className={`pill ${cls}`}>
      <span className="pill__dot" />
      {label}
    </span>
  );
};

// Maps an extractor icon name to a component
const ExtractorIcon = ({ name, size = 16 }) => {
  const map = {
    FileText: IconFileText,
    FileArchive: IconFileArchive,
    FileImage: IconFileImage,
    File: IconFile,
    Book: IconBook,
    Camera: IconCamera,
  };
  const Cmp = map[name] || IconFile;
  return <Cmp size={size} />;
};

Object.assign(window, {
  SNAPSHOT, NAV_ITEMS, Appbar, Statusbar, StatusPill, ExtractorIcon,
});
