#!/usr/bin/env python3
"""Capture a true full-page PNG via chromium DevTools.

Replaces the old `chromium --screenshot --window-size=W,16384` trick (which
produces a fixed-height PNG with mostly trailing whitespace). Instead we
launch headless chromium with --remote-debugging-port, drive it via the
CDP `Page.captureScreenshot` call with `captureBeyondViewport=true`, and
let chromium emit a PNG sized to the page's actual scrollHeight.

Usage: chromium-fullpage URL OUTPUT_PNG WIDTH PROXY [--ignore-cert]
  WIDTH    viewport width in CSS px (height auto-fits to page)
  PROXY    socks5://host:port URL passed via --proxy-server
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

from websocket import WebSocketTimeoutException, create_connection

URL, OUT, WIDTH_S, PROXY = sys.argv[1:5]
IGNORE_CERT = "--ignore-cert" in sys.argv[5:]
WIDTH = int(WIDTH_S)
PORT = int(os.environ.get("CDP_PORT", "9222"))
USER_DATA = tempfile.mkdtemp(prefix="chrome-cdp-")

flags = [
    "chromium",
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--hide-scrollbars",
    f"--user-data-dir={USER_DATA}",
    f"--remote-debugging-port={PORT}",
    "--remote-allow-origins=*",
    f"--proxy-server={PROXY}",
    f"--window-size={WIDTH},900",
    "about:blank",
]
if IGNORE_CERT:
    flags.insert(2, "--ignore-certificate-errors")

CHROMIUM_LOG = OUT + ".chromium.log"
chromium = subprocess.Popen(
    flags, stdout=subprocess.DEVNULL, stderr=open(CHROMIUM_LOG, "wb")
)

def find_browser_ws():
    deadline = time.time() + 30
    last_err = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{PORT}/json/version", timeout=1
            ) as r:
                return json.loads(r.read())["webSocketDebuggerUrl"]
        except Exception as e:
            last_err = e
            time.sleep(0.3)
    raise RuntimeError(f"chromium devtools never came up: {last_err}")

ws_url = find_browser_ws()
ws = create_connection(ws_url, timeout=120)
ws.settimeout(120)

_id = [0]

def send(method, params=None, sid=None):
    _id[0] += 1
    msg = {"id": _id[0], "method": method, "params": params or {}}
    if sid:
        msg["sessionId"] = sid
    ws.send(json.dumps(msg))
    return _id[0]

def recv_until(pred, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ws.settimeout(max(0.1, deadline - time.time()))
        msg = json.loads(ws.recv())
        if pred(msg):
            return msg
    raise RuntimeError("timeout waiting for CDP message")

def call(method, params=None, sid=None, timeout=120):
    """Send a CDP method and return its result, raising on error responses.

    The previous code did `recv_until(...)["result"]` and crashed with
    KeyError when CDP returned `{id, error}` instead of `{id, result}`,
    masking the real failure with an unhelpful traceback.
    """
    mid = send(method, params, sid)
    rsp = recv_until(lambda m: m.get("id") == mid, timeout=timeout)
    if "error" in rsp:
        raise RuntimeError(
            f"CDP error from {method}: {json.dumps(rsp['error'])}"
        )
    return rsp.get("result", {})

target_id = call("Target.createTarget", {"url": "about:blank"})["targetId"]

session_id = call(
    "Target.attachToTarget", {"targetId": target_id, "flatten": True}
)["sessionId"]

call("Page.enable", {}, session_id)
call("Page.setLifecycleEventsEnabled", {"enabled": True}, session_id)
call("Page.navigate", {"url": URL}, session_id)

deadline = time.time() + 60
got_idle = False
load_grace_until = None
while time.time() < deadline:
    try:
        ws.settimeout(max(0.1, deadline - time.time()))
        msg = json.loads(ws.recv())
    except WebSocketTimeoutException:
        break
    if msg.get("sessionId") != session_id:
        continue
    if msg.get("method") != "Page.lifecycleEvent":
        continue
    name = msg.get("params", {}).get("name")
    if name == "networkIdle":
        got_idle = True
        break
    if name == "load" and load_grace_until is None:
        load_grace_until = time.time() + 8
        deadline = min(deadline, load_grace_until)

time.sleep(1.5)

result = call(
    "Page.captureScreenshot",
    {"format": "png", "captureBeyondViewport": True, "fromSurface": True},
    session_id,
    timeout=180,
)

with open(OUT, "wb") as f:
    f.write(base64.b64decode(result["data"]))

ws.close()
chromium.terminate()
try:
    chromium.wait(timeout=10)
except subprocess.TimeoutExpired:
    chromium.kill()

print(
    f"captured {OUT} (width={WIDTH}, idle={got_idle}, load_seen={load_grace_until is not None})",
    file=sys.stderr,
)
