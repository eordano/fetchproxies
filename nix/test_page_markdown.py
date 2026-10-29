import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("page_markdown", Path(__file__).with_name("page-markdown.py"))
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)

ARTICLE = b"""<!doctype html><html><head><title>Install &amp; Use | Example</title>
<script>window.secret = "do-not-render";</script><style>body{color:red}</style></head>
<body><nav><a href="/">Home</a> <a href="/pricing">Pricing</a></nav>
<header><p>Site banner text</p></header>
<main><article><h1>Install guide</h1>
<p>Read the <a href="/docs/install">install docs</a> or <a href="javascript:alert(1)">click</a>.
Run it with snake_case_name and *stars*.</p>
<h2>Steps</h2><ol><li>Download</li><li>Run <code>make install</code></li></ol>
<ul><li>Linux<ul><li>NixOS</li></ul></li></ul>
<div class="highlight highlight-source-python"><pre>print("``` inside")</pre></div>
<pre><code class="language-bash">echo ok</code></pre>
<table><tr><th>OS</th><th>State</th></tr><tr><td>Linux</td><td>a|b</td></tr></table>
<img src="/logo.png" alt="Project logo"><img src="data:image/png;base64,AAAA" alt="inline">
<p hidden>hidden text</p><div aria-hidden="true">aria hidden</div>
</article></main>
<aside>Related posts</aside><footer>Copyright 2026</footer></body></html>"""


def page(body, content_type="text/html; charset=utf-8", url="https://example.com/docs/guide",
         final=None, status=200, clipped=False):
    return pm.Page(url, final or url, status, content_type, body, clipped)


def render(p, **kw):
    kw.setdefault("readable", None)
    kw.setdefault("fetched_at", "2026-10-29T10:00:00Z")
    kw.setdefault("archive_url", "https://fetch.example/artifacts/results/7/")
    return pm.render(p, **kw)


def front(markdown):
    head, _, body = markdown[4:].partition("\n---\n\n")
    return {k: json.loads(v) for k, _, v in (line.partition(": ") for line in head.splitlines())}, body


class HtmlRendition(unittest.TestCase):
    def setUp(self):
        self.md, self.meta = render(page(ARTICLE))
        self.fm, self.body = front(self.md)

    def test_front_matter_names_source_time_archive(self):
        self.assertEqual(self.fm["title"], "Install & Use | Example")
        self.assertEqual(self.fm["source"], "https://example.com/docs/guide")
        self.assertEqual(self.fm["fetched_at"], "2026-10-29T10:00:00Z")
        self.assertEqual(self.fm["archive"], "https://fetch.example/artifacts/results/7/")
        self.assertEqual(self.fm["http_status"], 200)
        self.assertEqual(self.fm["rendition"], "main")
        self.assertFalse(self.fm["truncated"])
        self.assertNotIn("final_url", self.fm)
        self.assertTrue(self.body.startswith("# Install & Use | Example\n"))

    def test_structure_survives(self):
        self.assertIn("# Install guide", self.body)
        self.assertIn("## Steps", self.body)
        self.assertIn("1. Download", self.body)
        self.assertIn("`make install`", self.body)
        self.assertIn("- Linux\n  - NixOS", self.body)
        self.assertIn("```bash\necho ok\n```", self.body)
        self.assertIn('````python\nprint("``` inside")\n````', self.body)
        self.assertIn("| OS | State |\n| --- | --- |\n| Linux | a\\|b |", self.body)
        self.assertIn("snake_case_name and *stars*", self.body)

    def test_links_are_absolute_and_scripts_go(self):
        self.assertIn("[install docs](https://example.com/docs/install)", self.body)
        self.assertIn("![Project logo](https://example.com/logo.png)", self.body)
        self.assertNotIn("javascript:", self.body)
        self.assertNotIn("data:image", self.body)

    def test_boilerplate_is_dropped(self):
        for gone in ("do-not-render", "color:red", "Pricing", "Site banner", "Related posts",
                     "Copyright", "hidden text", "aria hidden"):
            self.assertNotIn(gone, self.md)

    def test_layout_tables_icons_and_screen_reader_text(self):
        html = (b'<html><body><main><h2 class="sr-only">Repository navigation</h2>'
                b'<img src="/a.png" alt="@someone" width="40" height="40">'
                b"<table><tr><td><p>First comment</p></td></tr><tr><td><p>Second comment</p></td></tr></table>"
                b'<img src="https://example.com/diagram.png" alt="Architecture"></main></body></html>')
        _, body = front(render(page(html))[0])
        self.assertIn("First comment\n\nSecond comment", body)
        self.assertNotIn("|", body)
        self.assertNotIn("@someone", body)
        self.assertNotIn("Repository navigation", body)
        self.assertIn("![Architecture](https://example.com/diagram.png)", body)

    def test_readability_wins_when_it_keeps_most_text(self):
        article = {"title": "Install guide",
                   "html-content": '<div><h2>Install guide</h2><p>Read the <a href="https://example.com/docs/install">'
                                   "install docs</a>. Run it with snake_case_name and *stars*. Download Run make "
                                   "install Linux NixOS print echo ok OS State Linux a b</p></div>"}
        md, meta = render(page(ARTICLE), readable=lambda html, base: article)
        self.assertEqual(meta["rendition"], "readability")
        self.assertTrue(front(md)[1].startswith("# Install guide\n"))

    def test_thin_readability_falls_back_to_main(self):
        md, meta = render(page(ARTICLE), readable=lambda html, base: {"title": "x", "html-content": "<p>Only</p>"})
        self.assertEqual(meta["rendition"], "main")

    def test_script_shell_is_rendered_in_a_browser(self):
        shell = b'<html><head><title>App</title></head><body><div id="root"></div><script src="/app.js"></script></body></html>'
        dom = "<html><body><main><h1>Dashboard</h1><p>" + "Rendered content. " * 20 + "</p></main></body></html>"
        md, meta = render(page(shell), rerender=lambda url: dom)
        self.assertEqual(meta["rendition"], "main+rendered")
        self.assertIn("# Dashboard", md)

    def test_redirect_and_status_are_recorded(self):
        md, meta = render(page(b"<html><body><main><p>Gone</p></main></body></html>",
                               final="https://example.com/new", status=404))
        fm, _ = front(md)
        self.assertEqual(fm["final_url"], "https://example.com/new")
        self.assertEqual(fm["http_status"], 404)

    def test_charset_from_header(self):
        body = "<html><body><main><p>café</p></main></body></html>".encode("latin-1")
        md, _ = render(page(body, content_type="text/html; charset=iso-8859-1"))
        self.assertIn("café", md)


class OtherContent(unittest.TestCase):
    def test_json_is_pretty_and_fenced(self):
        md, meta = render(page(b'{"name":"x","topics":["a","b"]}', content_type="application/json",
                               url="https://api.github.com/repos/o/r"))
        self.assertEqual(meta["rendition"], "json")
        self.assertIn('```json\n{\n  "name": "x",', md)

    def test_raw_markdown_passes_through(self):
        md, meta = render(page(b"# Readme\n\nHello", content_type="text/plain; charset=utf-8",
                               url="https://raw.githubusercontent.com/o/r/main/README.md"))
        self.assertEqual(meta["rendition"], "markdown")
        self.assertIn("# Readme\n\nHello", md)

    def test_source_code_is_fenced_with_language(self):
        md, meta = render(page(b"fn main() {}\n", content_type="text/plain",
                               url="https://raw.githubusercontent.com/o/r/main/src/main.rs"))
        self.assertEqual(meta["rendition"], "code")
        self.assertIn("```rust\nfn main() {}\n```", md)

    def test_binary_is_described_not_rendered(self):
        md, meta = render(page(b"\x89PNG\r\n\x1a\n\x00\x00", content_type="image/png",
                               url="https://objects.githubusercontent.com/x.png"))
        self.assertEqual(meta["rendition"], "binary")
        self.assertIn("Binary content (image/png, 10 bytes)", md)

    def test_sniffs_html_without_content_type(self):
        self.assertEqual(pm.classify("", "https://e.com/", b"<!DOCTYPE html><html></html>"), "html")
        self.assertEqual(pm.classify("", "https://e.com/x", b'{"a":1}'), "json")
        self.assertEqual(pm.classify("", "https://e.com/x", b"\x00\x01\x02"), "binary")


class Bounds(unittest.TestCase):
    def test_rendition_is_bounded_and_marked(self):
        big = ("<html><body><main>" + "".join(f"<p>paragraph {i} " + "word " * 40 + "</p>" for i in range(2000))
               + "</main></body></html>").encode()
        md, meta = render(page(big), max_bytes=32 * 1024)
        self.assertLessEqual(len(md.encode()), 32 * 1024)
        self.assertTrue(meta["truncated"])
        self.assertTrue(front(md)[0]["truncated"])
        self.assertIn("[truncated: rendition exceeds", md)

    def test_bound_keeps_utf8_and_closes_fence(self):
        text = "```\n" + "é" * 5000 + "\n" + "x\n" * 100
        cut, clipped = pm.bound(text, 4000)
        self.assertTrue(clipped)
        self.assertLessEqual(len(cut.encode()), 4000)
        self.assertEqual(len([l for l in cut.splitlines() if l.startswith("```")]) % 2, 0)

    def test_clipped_fetch_is_marked(self):
        _, meta = render(page(b"<html><body><main><p>start</p></main></body></html>", clipped=True))
        self.assertTrue(meta["truncated"])

    def test_tidy_collapses_blank_lines_outside_fences(self):
        self.assertEqual(pm.tidy("a\n\n\n\nb\n```\n\n\n\nc\n```\n[](x)\n"), "a\n\nb\n```\n\n\n\nc\n```\n")


class Headers(unittest.TestCase):
    def test_redirect_chain(self):
        raw = ("HTTP/1.1 301 Moved\r\nLocation: /b\r\n\r\n"
               "HTTP/2 302\r\nlocation: https://other.example/c\r\n\r\n"
               "HTTP/2 200\r\ncontent-type: text/html; charset=utf-8\r\n\r\n")
        self.assertEqual(pm.parse_headers(raw, "https://example.com/a"),
                         (200, "text/html; charset=utf-8", "https://other.example/c"))

    def test_final_redirect_without_follow(self):
        raw = "HTTP/1.1 302 Found\r\nLocation: https://x.example/\r\n\r\n"
        self.assertEqual(pm.parse_headers(raw, "https://example.com/")[0], 302)

    def test_front_matter_escapes(self):
        text = pm.front_matter({"title": 'a "quoted"\ntitle', "truncated": False})
        self.assertIn('title: "a \\"quoted\\"\\ntitle"', text)
        self.assertIn("truncated: false", text)


if __name__ == "__main__":
    unittest.main()
