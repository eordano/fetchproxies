#!/usr/bin/env python3
"""Render one URL as Markdown for agents.

Usage: page-markdown URL OUTDIR PROXY [--archive-url URL] [--max-bytes N]

Fetches URL through PROXY (socks5://host:port) and writes OUTDIR/page.md (the
rendition: YAML front matter, then the page), OUTDIR/page.json (the same
metadata for the worker), OUTDIR/source.<ext> (the bytes fetched) and
OUTDIR/headers.txt. Exit 0 rendered (any HTTP status), 1 transient (the fetch
itself failed), 2 bad arguments.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from urllib.parse import urljoin, urlsplit

from bs4 import BeautifulSoup, Comment, UnicodeDammit
from markdownify import MarkdownConverter

FETCH_LIMIT = 8 * 1024 * 1024
MAX_BYTES = 256 * 1024
HEADROOM = 2048
FETCH_TIMEOUT = 60
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)
ACCEPT = (
    "text/html,application/xhtml+xml,text/markdown;q=0.9,"
    "text/plain;q=0.8,application/json;q=0.8,*/*;q=0.5"
)

ALWAYS_DROP = [
    "script", "style", "noscript", "template", "svg", "canvas", "iframe",
    "object", "embed", "form", "button", "input", "select", "textarea",
    "link", "meta", "dialog",
]
CHROME_TAGS = ["nav", "aside"]
SCREEN_READER_ONLY = re.compile(r"(?i)sr-only|visually-?hidden|screen-reader")
CHROME_ROLES = {
    "navigation", "banner", "contentinfo", "complementary", "search",
    "menu", "menubar", "toolbar",
}
TEXT_TYPES = {
    "application/javascript", "application/x-javascript", "application/ecmascript",
    "application/xml", "application/x-yaml", "application/yaml", "application/toml",
    "application/x-sh", "application/sql", "application/x-httpd-php",
}
PROSE_EXTENSIONS = {"", "txt", "text", "rst", "adoc", "log", "org"}
MARKDOWN_EXTENSIONS = {"md", "markdown", "mdx"}
LANGUAGES = {
    "py": "python", "rs": "rust", "js": "javascript", "mjs": "javascript",
    "ts": "typescript", "tsx": "tsx", "jsx": "jsx", "sh": "bash", "bash": "bash",
    "nix": "nix", "go": "go", "rb": "ruby", "c": "c", "h": "c", "cc": "cpp",
    "cpp": "cpp", "hpp": "cpp", "java": "java", "kt": "kotlin", "swift": "swift",
    "cs": "csharp", "php": "php", "lua": "lua", "toml": "toml", "yaml": "yaml",
    "yml": "yaml", "json": "json", "xml": "xml", "html": "html", "css": "css",
    "sql": "sql", "diff": "diff", "patch": "diff", "ex": "elixir", "exs": "elixir",
    "hs": "haskell", "ml": "ocaml", "zig": "zig", "dockerfile": "dockerfile",
    "proto": "protobuf", "csv": "csv",
}
SOURCE_EXTENSIONS = {"html": "html", "json": "json", "markdown": "md", "text": "txt"}


class Page:
    def __init__(self, url, final_url, status, content_type, body, clipped=False):
        self.url = url
        self.final_url = final_url
        self.status = status
        self.content_type = content_type
        self.body = body
        self.clipped = clipped


class FetchError(Exception):
    pass


def socks_h(proxy):
    return re.sub(r"^socks5://", "socks5h://", proxy)


def parse_headers(text, url):
    """Status, content type and final URL from curl -D output across redirects."""
    blocks = [b for b in re.split(r"\r?\n\r?\n", text) if b.strip().startswith("HTTP/")]
    status, content_type, final = None, "", url
    for i, block in enumerate(blocks):
        lines = block.strip().splitlines()
        match = re.match(r"HTTP/\S+\s+(\d{3})", lines[0])
        code = int(match.group(1)) if match else None
        fields = {}
        for line in lines[1:]:
            name, sep, value = line.partition(":")
            if sep:
                fields[name.strip().lower()] = value.strip()
        if code is not None and 300 <= code < 400 and "location" in fields and i < len(blocks) - 1:
            final = urljoin(final, fields["location"])
            continue
        if code == 100:
            continue
        status, content_type = code, fields.get("content-type", "")
    return status, content_type, final


def fetch(url, proxy, outdir, limit=FETCH_LIMIT, timeout=FETCH_TIMEOUT):
    headers_path = os.path.join(outdir, "headers.txt")
    cmd = [
        "curl", "-sS", "-L", "--max-redirs", "5",
        "--proto", "=http,https", "--proto-redir", "=http,https",
        "--compressed", "--max-time", str(timeout),
        "-A", USER_AGENT, "-H", "Accept: " + ACCEPT,
        "-D", headers_path, "-o", "-",
    ]
    if proxy:
        cmd += ["-x", socks_h(proxy)]
    cmd.append(url)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    body = proc.stdout.read(limit + 1)
    clipped = len(body) > limit
    if clipped:
        proc.kill()
        body = body[:limit]
    _, err = proc.communicate(timeout=timeout + 15)
    try:
        with open(headers_path, encoding="latin-1") as f:
            head = f.read()
    except OSError:
        head = ""
    status, content_type, final = parse_headers(head, url)
    if not clipped and proc.returncode != 0:
        raise FetchError(f"curl exit {proc.returncode}: {err.decode(errors='replace').strip()[:300]}")
    if status is None:
        raise FetchError("no HTTP response")
    return Page(url, final, status, content_type, body, clipped)


def extension(url):
    name = urlsplit(url).path.rsplit("/", 1)[-1].lower()
    if name == "dockerfile":
        return "dockerfile"
    return name.rsplit(".", 1)[-1] if "." in name else ""


def charset_of(content_type):
    match = re.search(r"charset=[\"']?([A-Za-z0-9._-]+)", content_type or "", re.I)
    return match.group(1) if match else None


def classify(content_type, url, body):
    ct = (content_type or "").split(";")[0].strip().lower()
    ext = extension(url)
    if ct in ("text/html", "application/xhtml+xml"):
        return "html"
    if ct == "application/json" or ct.endswith("+json"):
        return "json"
    if ct in ("text/markdown", "text/x-markdown"):
        return "markdown"
    if ct.startswith("text/") or ct in TEXT_TYPES:
        return "markdown" if ext in MARKDOWN_EXTENSIONS else "text"
    if not ct or ct == "application/octet-stream":
        head = body[:1024].lstrip().lower()
        if head.startswith(b"<!doctype html") or b"<html" in head:
            return "html"
        try:
            json.loads(body.decode("utf-8"))
            return "json"
        except ValueError:
            pass
        if b"\x00" not in body[:8192]:
            try:
                body.decode("utf-8")
                return "markdown" if ext in MARKDOWN_EXTENSIONS else "text"
            except UnicodeDecodeError:
                pass
    return "binary"


def decode(body, content_type, html=False):
    hints = [c for c in [charset_of(content_type)] if c]
    text = UnicodeDammit(body, hints, is_html=html).unicode_markup
    return (text if text is not None else body.decode("utf-8", "replace")).replace("\x00", "")


def fence(text, lang=""):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}{lang}\n{text.rstrip()}\n{ticks}"


def code_language(el):
    for node in (el, el.find("code"), el.parent):
        if node is None or not hasattr(node, "get"):
            continue
        for cls in node.get("class") or []:
            for prefix in ("language-", "lang-", "highlight-source-"):
                if cls.startswith(prefix):
                    return cls[len(prefix):]
    return ""


class AgentMarkdown(MarkdownConverter):
    def convert_img(self, el, text, parent_tags):
        alt = " ".join((el.get("alt") or "").split())
        src = el.get("src") or ""
        if not alt or not src.startswith(("http://", "https://")):
            return ""
        if "_inline" in parent_tags or len(src) > 200:
            return f"[image: {alt}]"
        return f"![{alt}]({src})"

    def convert_pre(self, el, text, parent_tags):
        return "\n\n" + fence(text.strip("\n"), code_language(el)) + "\n\n" if text else ""

    def convert_td(self, el, text, parent_tags):
        return super().convert_td(el, text.replace("|", "\\|"), parent_tags)

    def convert_th(self, el, text, parent_tags):
        return super().convert_th(el, text.replace("|", "\\|"), parent_tags)


def to_markdown(node):
    return AgentMarkdown(
        heading_style="atx",
        bullets="-",
        escape_underscores=False,
        escape_asterisks=False,
        escape_misc=False,
        table_infer_header=True,
        code_language_callback=code_language,
    ).convert_soup(node)


def clean(soup, base, chrome):
    for c in soup.find_all(string=lambda s: isinstance(s, Comment)):
        c.extract()
    for t in soup.find_all(ALWAYS_DROP):
        t.decompose()
    for t in soup.find_all(True):
        if t.decomposed or t.attrs is None:
            continue
        style = (t.get("style") or "").replace(" ", "").lower()
        if (
            t.has_attr("hidden")
            or t.get("aria-hidden") == "true"
            or "display:none" in style
            or any(SCREEN_READER_ONLY.search(c) for c in t.get("class") or [])
            or (t.name == "img" and small_image(t))
            or (chrome and t.get("role") in CHROME_ROLES)
        ):
            t.decompose()
    if chrome:
        for t in soup.find_all(CHROME_TAGS):
            t.decompose()
        for t in soup.find_all(["header", "footer"]):
            if not t.decomposed and t.find_parent(["article", "main"]) is None:
                t.decompose()
    for a in soup.find_all("a"):
        href = (a.get("href") or "").strip()
        if not href or href.startswith("#") or re.match(r"(?i)(javascript|data|vbscript):", href):
            a.attrs.pop("href", None)
        else:
            a["href"] = urljoin(base, href)
    for img in soup.find_all("img"):
        src = (img.get("src") or "").strip()
        img["src"] = urljoin(base, src) if src and not src.startswith("data:") else ""
    for table in soup.find_all("table"):
        if table.decomposed:
            continue
        own = [c for c in table.find_all(["tr", "td", "th", "tbody", "thead", "tfoot"])
               if c.find_parent("table") is table]
        if all(len(r.find_all(["td", "th"], recursive=False)) <= 1 for r in own if r.name == "tr"):
            for c in own:
                if c.name in ("td", "th"):
                    c.name = "div"
                else:
                    c.unwrap()
            table.name = "div"
    return soup


def small_image(img):
    sizes = [img.get("width"), img.get("height")]
    return any(s and str(s).isdigit() and int(s) <= 64 for s in sizes)


def text_length(soup):
    return len(" ".join(soup.get_text(" ").split())) if soup is not None else 0


def page_title(soup):
    for sel in (("meta", {"property": "og:title"}), ("title", {}), ("h1", {})):
        el = soup.find(*sel)
        if el is None:
            continue
        value = el.get("content") if el.name == "meta" else el.get_text(" ")
        value = " ".join((value or "").split())
        if value:
            return value[:300]
    return ""


def run_readable(html, base):
    try:
        proc = subprocess.run(
            ["readable", "--base", base, "--json", "--quiet", "--keep-classes",
             "--low-confidence", "keep", "-"],
            input=html.encode(), capture_output=True, timeout=60,
        )
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def render_dom(url, proxy):
    try:
        proc = subprocess.run(
            ["chromium", "--headless=new", "--no-sandbox", "--disable-gpu",
             "--disable-dev-shm-usage", "--hide-scrollbars",
             "--user-data-dir=/tmp/chrome-markdown", "--virtual-time-budget=15000",
             f"--proxy-server={proxy}", "--dump-dom", url],
            capture_output=True, timeout=90,
        )
        return proc.stdout.decode("utf-8", "replace") if proc.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def html_body(html, base, readable=run_readable):
    """Markdown body, title and the rendition chosen for an HTML document."""
    soup = BeautifulSoup(html, "html.parser")
    if soup.base and soup.base.get("href"):
        base = urljoin(base, soup.base["href"])
    title = page_title(soup)
    page = clean(soup, base, chrome=True)
    main = page.find("main") or page.find(attrs={"role": "main"})
    reference = main if main is not None and text_length(main) > 0 else (page.body or page)
    reference_len = text_length(reference)
    article = readable(html, base) if readable else None
    if article and article.get("html-content"):
        node = clean(BeautifulSoup(article["html-content"], "html.parser"), base, chrome=False)
        if text_length(node) >= 0.5 * reference_len and text_length(node) > 0:
            return to_markdown(node), (article.get("title") or title), "readability"
    return to_markdown(reference), title, "main" if reference is main else "page"


def tidy(md):
    out, blank, in_fence = [], 0, None
    for line in md.replace("\r", "").split("\n"):
        stripped = line.strip()
        marker = re.match(r"(`{3,}|~{3,})", stripped)
        if marker and (in_fence is None or stripped.startswith(in_fence)):
            in_fence = None if in_fence else marker.group(1)
            out.append(line.rstrip())
            blank = 0
            continue
        if in_fence:
            out.append(line.rstrip())
            continue
        line = re.sub(r"\[\]\([^)]*\)", "", line).rstrip()
        if not line.strip():
            blank += 1
            if blank > 1:
                continue
            line = ""
        else:
            blank = 0
        out.append(line)
    return "\n".join(out).strip() + "\n"


def bound(text, limit):
    """Cut text to at most limit UTF-8 bytes on a line boundary; close an open fence."""
    data = text.encode()
    if len(data) <= limit:
        return text, False
    note = f"\n\n[truncated: rendition exceeds {limit} bytes; the archive holds the full page]\n"
    budget = max(0, limit - len(note.encode()) - 16)
    cut = data[:budget].decode("utf-8", "ignore")
    newline = cut.rfind("\n")
    if newline > budget // 2:
        cut = cut[:newline]
    fences = [m.group(1) for m in re.finditer(r"(?m)^\s*(`{3,}|~{3,})", cut)]
    if len(fences) % 2:
        cut += "\n" + fences[-1]
    return cut + note, True


def front_matter(meta):
    keys = ["title", "source", "final_url", "fetched_at", "http_status",
            "content_type", "archive", "rendition", "truncated"]
    lines = ["---"]
    for key in keys:
        if key not in meta or meta[key] in (None, ""):
            continue
        value = meta[key]
        lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def render(page, archive_url="", fetched_at=None, max_bytes=MAX_BYTES,
           readable=run_readable, rerender=None):
    """(markdown, meta) for a fetched page."""
    fetched_at = fetched_at or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    kind = classify(page.content_type, page.final_url, page.body)
    title = ""
    if kind == "html":
        html = decode(page.body, page.content_type, html=True)
        body, title, rendition = html_body(html, page.final_url, readable)
        if rerender and len(body.strip()) < 200 and re.search(r"(?i)<script", html):
            dom = rerender(page.final_url)
            if dom:
                body, title2, rendition = html_body(dom, page.final_url, readable)
                title = title2 or title
                rendition += "+rendered"
    elif kind == "json":
        text = decode(page.body, page.content_type)
        try:
            text = json.dumps(json.loads(text), indent=2, ensure_ascii=False)
        except ValueError:
            pass
        body, rendition = fence(text, "json"), "json"
    elif kind == "markdown":
        body, rendition = decode(page.body, page.content_type), "markdown"
    elif kind == "text":
        text = decode(page.body, page.content_type)
        ext = extension(page.final_url)
        if ext in PROSE_EXTENSIONS:
            body, rendition = text, "text"
        else:
            body, rendition = fence(text, LANGUAGES.get(ext, ext if ext.isalnum() else "")), "code"
    else:
        ct = (page.content_type or "unknown").split(";")[0].strip()
        body = (f"Binary content ({ct}, {len(page.body)} bytes{'+' if page.clipped else ''}) "
                "is not rendered as Markdown; the archive holds the file.")
        rendition = "binary"
    body = tidy(body)
    title = " ".join((title or "").split())[:300]
    if title and not re.match(r"#\s+" + re.escape(title) + r"\s*$", body.split("\n", 1)[0]):
        body = f"# {title}\n\n{body}"
    meta = {
        "title": title,
        "source": page.url,
        "final_url": page.final_url if page.final_url != page.url else "",
        "fetched_at": fetched_at,
        "http_status": page.status,
        "content_type": (page.content_type or "").split(";")[0].strip(),
        "archive": archive_url,
        "rendition": rendition,
        "truncated": page.clipped,
        "source_clipped": page.clipped,
        "kind": kind,
    }
    body, cut = bound(body, max_bytes - HEADROOM)
    meta["truncated"] = page.clipped or cut
    markdown = front_matter(meta) + body
    meta["bytes"] = len(markdown.encode())
    return markdown, meta


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("outdir")
    parser.add_argument("proxy")
    parser.add_argument("--archive-url", default="")
    parser.add_argument("--max-bytes", type=int, default=MAX_BYTES)
    args = parser.parse_args(argv)
    if not re.match(r"(?i)https?://", args.url) or args.max_bytes < 4 * HEADROOM:
        print("page-markdown: need an http(s) URL and --max-bytes >= 8192", file=sys.stderr)
        return 2
    os.makedirs(args.outdir, exist_ok=True)
    try:
        page = fetch(args.url, args.proxy, args.outdir)
    except (FetchError, OSError, subprocess.TimeoutExpired) as error:
        print(f"page-markdown: fetch failed: {error}", file=sys.stderr)
        return 1
    markdown, meta = render(
        page, archive_url=args.archive_url, max_bytes=args.max_bytes,
        rerender=lambda u: render_dom(u, args.proxy),
    )
    kind = meta["kind"]
    with open(os.path.join(args.outdir, "source." + SOURCE_EXTENSIONS.get(kind, "bin")), "wb") as f:
        f.write(page.body)
    with open(os.path.join(args.outdir, "page.md"), "w", encoding="utf-8") as f:
        f.write(markdown)
    with open(os.path.join(args.outdir, "page.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    print(f"page-markdown: {meta['http_status']} {kind}/{meta['rendition']} "
          f"{meta['bytes']} bytes truncated={meta['truncated']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
