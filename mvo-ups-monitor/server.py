#!/usr/bin/env python3
"""UPS Monitor web UI + widget server.

Serves on port 8099 (behind Umbrel's app_proxy), dual-stack IPv4+IPv6:
  GET  /                  -> status dashboard + settings form
  POST /save              -> validate + persist settings, or re-render with inline errors
  GET  /widgets/status    -> four-stats JSON for the Umbrel dashboard widget

Security:
  - Every submitted value is whitelist-validated here; the config file is written as
    plain KEY=value and PARSED (never sourced) by watch.sh, so a value can never run
    as a shell command.
  - POST requires a matching CSRF token (embedded in the form) AND a same-origin
    Origin header when one is present. Request body size is capped.
"""
import os
import re
import socket
import json
import html
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_VERSION = "0.6.2"   # keep in sync with umbrel-app.yml / docker-compose.yml / workflow
STATE_DIR = "/state"
CONFIG = os.path.join(STATE_DIR, "config.env")
PORT = 8099
MAX_BODY = 8192
CSRF_TOKEN = os.urandom(16).hex()

# key, label, default, input-attrs, help text, validation regex (full-match; empty allowed)
FIELDS = [
    ("NUT_HOST", "UPS server address", "", 'type="text"',
     "The device running NUT on your network — often your NAS or the machine your UPS is plugged into. IP or hostname.",
     r"[A-Za-z0-9.\-]{1,253}"),
    ("NUT_PORT", "UPS server port", "3493", 'type="number" min="1" max="65535"',
     "Leave as 3493 unless you changed it.",
     r"[0-9]{1,5}"),
    ("NUT_UPS", "UPS name", "ups", 'type="text"',
     "The name your UPS is registered under on the server — usually “ups”.",
     r"[A-Za-z0-9._\-]{1,64}"),
    ("SHUTDOWN_AT_PERCENT", "Shut down early at battery %", "", 'type="number" min="1" max="100"',
     "Optional. Umbrel shuts down when the battery reaches this level (e.g. 20). Leave blank to wait until the UPS reports critical low battery.",
     r"100|[0-9]{1,2}"),
    ("CHECK_INTERVAL", "How often to check (seconds)", "15", 'type="number" min="1" max="3600"',
     "How often to poll the UPS server.",
     r"[0-9]{1,4}"),
]
KEYS = [f[0] for f in FIELDS]
VALIDATORS = {f[0]: re.compile("^(%s)$" % f[5]) for f in FIELDS}


def valid(key, value):
    value = value.strip()
    if value == "":
        return True
    return bool(VALIDATORS[key].match(value))


def load_config():
    cfg = {k: os.environ.get(k, d) for k, _, d, _, _, _ in FIELDS}
    try:
        with open(CONFIG) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k in cfg:
                    cfg[k] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    return cfg


def save_config(values):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("# Written by the UPS Monitor settings page. Parsed (not sourced) by watch.sh.\n")
        for k in KEYS:
            v = values.get(k, "").strip()
            if not valid(k, v):
                v = ""
            fh.write('%s=%s\n' % (k, v))
    os.replace(tmp, CONFIG)


def nut_get(cfg, var):
    host, port, ups = cfg.get("NUT_HOST", ""), cfg.get("NUT_PORT", "3493"), cfg.get("NUT_UPS", "ups")
    if not host:
        return None
    try:
        with socket.create_connection((host, int(port)), timeout=3) as s:
            s.sendall(("GET VAR %s %s\nLOGOUT\n" % (ups, var)).encode())
            data = s.recv(4096).decode(errors="ignore")
        for line in data.splitlines():
            if line.startswith("VAR") and '"' in line:
                return line.split('"')[1]
    except Exception:
        return None
    return None


def widget_payload(cfg):
    st = nut_get(cfg, "ups.status")
    if st is None:
        sub = "not configured" if not cfg.get("NUT_HOST") else "no NUT"
        return {"type": "four-stats", "refresh": "10s", "link": "", "items": [
            {"title": "UPS", "text": "offline", "subtext": sub},
            {"title": "", "text": "", "subtext": ""},
            {"title": "", "text": "", "subtext": ""},
            {"title": "", "text": "", "subtext": ""}]}
    tokens = st.split()
    status = "Online"
    if "OB" in tokens:
        status = "On Battery"
    if "LB" in tokens:
        status = "Low Battery"
    charge = nut_get(cfg, "battery.charge") or "?"
    runtime = nut_get(cfg, "battery.runtime")
    runtime_min = str(int(runtime) // 60) if runtime and runtime.isdigit() else "?"
    load = nut_get(cfg, "ups.load") or "?"
    return {"type": "four-stats", "refresh": "10s", "link": "", "items": [
        {"title": "Status", "text": status, "subtext": ""},
        {"title": "Battery", "text": charge, "subtext": "%"},
        {"title": "Runtime", "text": runtime_min, "subtext": "min"},
        {"title": "Load", "text": load, "subtext": "%"}]}


def _badge(cfg):
    if not cfg.get("NUT_HOST"):
        return "neutral", "Not configured"
    st = nut_get(cfg, "ups.status")
    if st is None:
        return "warn", "Unreachable"
    tokens = st.split()
    if "LB" in tokens:
        return "crit", "Low Battery"
    if "OB" in tokens:
        return "warn", "On Battery"
    return "ok", "Online"


def page(cfg, saved=False, errors=None, form_values=None):
    errors = errors or {}
    fv = form_values if form_values is not None else cfg
    badge_class, badge_text = _badge(cfg)
    configured = bool(cfg.get("NUT_HOST"))

    if configured:
        w = widget_payload(cfg)
        body_top = '<div class="cards">%s</div>' % "".join(
            '<div class="card"><div class="v">%s</div><div class="l">%s%s</div></div>' % (
                html.escape(i["text"] or "—"), html.escape(i["title"] or ""),
                (" (%s)" % html.escape(i["subtext"]) if i["subtext"] else ""))
            for i in w["items"] if i["title"] or i["text"])
    else:
        body_top = ('<div class="cta"><strong>Not connected yet.</strong> '
                    'Enter your UPS server details below and save to start monitoring.</div>')

    rows = ""
    for k, label, default, attrs, hint, _rx in FIELDS:
        val = html.escape(fv.get(k, ""))
        ph = ('placeholder="%s"' % html.escape(default)) if default else ""
        err = errors.get(k)
        err_html = '<span class="err">%s</span>' % html.escape(err) if err else ""
        inv = ' class="invalid"' if err else ""
        rows += ('<label>%s<input %s name="%s" value="%s" %s%s>'
                 '<span class="hint">%s</span>%s</label>'
                 % (html.escape(label), attrs, k, val, ph, inv, html.escape(hint), err_html))

    saved_note = '<div class="saved">Saved. Changes apply within one poll interval.</div>' if saved else ""
    err_note = '<div class="errbox">Some values were not valid — please correct the highlighted fields.</div>' if errors else ""
    strip_saved = '<script>if(location.search){history.replaceState({},"",location.pathname)}</script>' if saved else ""

    return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>UPS Monitor</title><style>
:root{color-scheme:dark}
body{margin:0;font-family:system-ui,sans-serif;background:#0b0f14;color:#e5e7eb;padding:24px}
.wrap{max-width:640px;margin:0 auto}
h1{font-size:20px;margin:0 0 4px;display:flex;align-items:center;gap:10px}
.badge{font-size:12px;padding:3px 10px;border-radius:999px}
.badge.ok{background:#064e3b;color:#4ade80}
.badge.warn{background:#7c2d12;color:#fdba74}
.badge.crit{background:#7f1d1d;color:#fca5a5}
.badge.neutral{background:#334155;color:#cbd5e1}
.sub{color:#9ca3af;font-size:13px;margin:0 0 20px}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:24px}
.card{background:#1f2933;border-radius:12px;padding:14px;text-align:center}
.card .v{font-size:22px;font-weight:600}.card .l{color:#9ca3af;font-size:12px;margin-top:4px}
.cta{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:16px;margin-bottom:24px;font-size:14px;line-height:1.5}
form{background:#111827;border-radius:12px;padding:18px;display:grid;gap:16px}
label{display:grid;gap:5px;font-size:13px;color:#cbd5e1;font-weight:600}
input{background:#0b0f14;border:1px solid #374151;border-radius:8px;padding:9px 11px;color:#e5e7eb;font-size:14px}
input.invalid{border-color:#f87171}
input:focus{outline:2px solid #4ade80;outline-offset:2px}
.hint{color:#b6bfca;font-size:12px;font-weight:400;line-height:1.5}
.err{color:#fca5a5;font-size:12px;font-weight:600}
button{background:#4ade80;color:#052e16;border:0;border-radius:8px;padding:11px;font-size:14px;font-weight:600;cursor:pointer;margin-top:2px}
button:hover{filter:brightness(1.08)}
button:focus-visible{outline:2px solid #fff;outline-offset:2px}
.saved{background:#064e3b;color:#4ade80;padding:10px 14px;border-radius:8px;margin-bottom:16px;font-size:14px}
.errbox{background:#7f1d1d;color:#fca5a5;padding:10px 14px;border-radius:8px;margin-bottom:16px;font-size:14px}
.ver{color:#6b7280;font-size:11px;text-align:center;margin:16px 0 0}
@media(max-width:520px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body><div class="wrap">
<h1>UPS Monitor <span class="badge %s">%s</span></h1>
<p class="sub">Gracefully shuts down Umbrel when a remote UPS runs low during a power outage.</p>
%s%s%s
<form method="post" action="/save">%s<input type="hidden" name="_csrf" value="%s"><button type="submit">Save settings</button></form>
<p class="ver">UPS Monitor v%s</p>
</div>%s</body></html>""" % (
        badge_class, html.escape(badge_text), saved_note, err_note, body_top,
        rows, CSRF_TOKEN, APP_VERSION, strip_saved)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        cfg = load_config()
        if path.startswith("/widgets"):
            self._send(200, json.dumps(widget_payload(cfg)), "application/json")
        else:
            saved = bool(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("saved"))
            self._send(200, page(cfg, saved=saved), "text/html; charset=utf-8")

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        try:
            return urllib.parse.urlparse(origin).netloc == (self.headers.get("Host") or "")
        except Exception:
            return False

    def do_POST(self):
        if not self._origin_ok():
            self._send(403, "forbidden", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._send(400, "bad request", "text/plain")
            return
        if length < 0 or length > MAX_BODY:
            self._send(413, "payload too large", "text/plain")
            return
        raw = self.rfile.read(length).decode(errors="ignore")
        posted = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
        if posted.get("_csrf") != CSRF_TOKEN:
            self._send(403, "forbidden", "text/plain")
            return
        values = {k: posted.get(k, "") for k in KEYS}
        errors = {}
        for k, label, _d, _a, _h, _rx in FIELDS:
            if not valid(k, values[k]):
                errors[k] = "Enter a valid value."
        if errors:
            cfg = load_config()
            self._send(200, page(cfg, errors=errors, form_values=values), "text/html; charset=utf-8")
            return
        save_config(values)
        self.send_response(303)
        self.send_header("Location", "/?saved=1")
        self.end_headers()

    def log_message(self, *args):
        pass


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
    timeout = 10

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except (AttributeError, OSError):
            pass
        super().server_bind()

    def get_request(self):
        conn, addr = super().get_request()
        conn.settimeout(15)  # guard against slow-loris style stalls
        return conn, addr


if __name__ == "__main__":
    os.makedirs(STATE_DIR, exist_ok=True)
    DualStackServer(("", PORT), Handler).serve_forever()
