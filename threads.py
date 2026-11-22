#!/usr/bin/env python3
"""
threads.py: one overview of every Claude Code thread across all your projects.

It reads your Claude Code login (the one the `claude` CLI already uses) and asks
the same session API the CLI uses for each session's title, project and state.
Read-only: it never changes a session and never writes your credentials anywhere.

Usage:
  python3 threads.py              # terminal overview (open threads + done in last 3 days)
  python3 threads.py --days 7     # show finished threads from the last 7 days
  python3 threads.py --all        # include archived / resolved sessions too
  python3 threads.py --html       # also write overview.html next to this script and open it
  python3 threads.py --json       # raw normalised rows, for piping into other tools
  python3 threads.py --debug      # print request URLs and response shapes (never the token)

Standard library only; needs macOS (Keychain) or CLAUDE_OVERVIEW_TOKEN + CLAUDE_OVERVIEW_ORG set.
NOTE: this uses an internal, undocumented API. It can change without notice.
"""
import argparse
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

BASE = os.environ.get("CLAUDE_OVERVIEW_BASE", "https://api.anthropic.com")
DEBUG = False

STATE_ORDER = ["blocked", "failed", "working", "review_ready", "completed", "unknown"]
STATE_LABEL = {
    "blocked": "Needs you",
    "failed": "Failed",
    "working": "Working",
    "review_ready": "Ready for review",
    "completed": "Done",
    "unknown": "Other",
}
STATE_ICON = {"blocked": "!", "failed": "x", "working": "~", "review_ready": "?", "completed": ".", "unknown": " "}


def log(*a):
    if DEBUG:
        print("[debug]", *a, file=sys.stderr)


# ---------------------------------------------------------------- credentials
def load_credentials():
    token = os.environ.get("CLAUDE_OVERVIEW_TOKEN")
    org = os.environ.get("CLAUDE_OVERVIEW_ORG")
    expires_at = None
    if not token:
        try:
            raw = subprocess.run(
                ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except (FileNotFoundError, subprocess.CalledProcessError):
            sys.exit("Couldn't read the Claude Code login from Keychain. Sign in with `claude` first "
                     "(or set CLAUDE_OVERVIEW_TOKEN).")
        data = json.loads(raw)
        oauth = data.get("claudeAiOauth") or {}
        token = oauth.get("accessToken")
        expires_at = oauth.get("expiresAt")
        if not token:
            sys.exit("Keychain entry has no access token. Run `claude` and sign in again.")
    if not org:
        cfg = Path.home() / ".claude.json"
        try:
            org = (json.loads(cfg.read_text()).get("oauthAccount") or {}).get("organizationUuid")
        except (OSError, ValueError):
            org = None
    if expires_at and expires_at / 1000 < dt.datetime.now().timestamp():
        sys.exit("Your Claude Code login token has expired. Start `claude` once (it refreshes the "
                 "token), quit it, then run this again.")
    return token, org


# ---------------------------------------------------------------- API
def api_get(path, token, org):
    url = BASE + path
    headers = {
        "Authorization": f"Bearer {token}",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "ccr-byoc-2025-07-29",
        "Content-Type": "application/json",
        "User-Agent": "thread-overview/0.1",
    }
    if org:
        headers["x-organization-uuid"] = org
    log("GET", url)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        log("HTTP", e.code, detail)
        return e.code, None
    if DEBUG:
        keys = list(body.keys()) if isinstance(body, dict) else type(body).__name__
        log("-> keys:", keys)
    return 200, body


def rows_of(body):
    if isinstance(body, list):
        return body
    for k in ("data", "sessions", "items"):
        if isinstance(body.get(k), list):
            return body[k]
    return []


def fetch_sessions(token, org, tags=None, max_pages=10, required=True):
    """Page through the session list. Tries the current endpoint, then the older one."""
    tag_q = "".join(f"&tags={urllib.parse.quote(t)}" for t in (tags or []))
    for base_path in ("/v1/code/sessions?limit=100", "/v1/sessions?beta=true&limit=100"):
        out, status, extra, seen = [], None, "", set()
        for _ in range(max_pages):
            status, body = api_get(base_path + tag_q + extra, token, org)
            if status != 200:
                break
            page = [r for r in rows_of(body) if r.get("id") not in seen]
            seen.update(r.get("id") for r in page)
            out.extend(page)
            log("  page rows:", len(page))
            if tags and page and not all(set(tags) & set(r.get("tags") or []) for r in page):
                log("  tag filter ignored by server; not paging this listing")
                break
            if not isinstance(body, dict) or not page:
                break
            if body.get("next_cursor"):
                extra = "&cursor=" + urllib.parse.quote(str(body["next_cursor"]))
            elif body.get("has_more") and body.get("last_id"):
                extra = "&after_id=" + urllib.parse.quote(str(body["last_id"]))
            else:
                break
        if status == 200:
            return out
        if not required:
            log("optional listing failed with HTTP", status)
            return []
        if status in (401, 403):
            sys.exit(f"The session API refused the login (HTTP {status}). Start `claude` once to refresh "
                     "the token and try again. If it keeps failing, this login can't read sessions.")
    sys.exit(f"Couldn't list sessions (last HTTP status {status}). Run with --debug for details.")


# ---------------------------------------------------------------- normalise
def norm_state(s):
    b = (s.get("status_bucket") or "").upper().replace("SESSION_STATUS_BUCKET_", "").lower()
    if b in STATE_LABEL:
        return b
    st = (s.get("session_status") or s.get("status") or "").lower()
    if "running" in st:
        return "working"
    return "unknown"


def summary_of(s):
    pts = s.get("post_turn_summary") or (s.get("external_metadata") or {}).get("post_turn_summary") or {}
    return (pts.get("needs_action") or "").strip(), (pts.get("recent_action") or "").strip()


def parse_time(v):
    if not v:
        return None
    try:
        return dt.datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None


def ago(t):
    if not t:
        return "?"
    secs = (dt.datetime.now(dt.timezone.utc) - t).total_seconds()
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return f"{int(secs // n)}{unit} ago"
    return "just now"


COORD_RE = re.compile(r'Project coordinator \("(.+)"\)')
CHAN_CACHE = Path.home() / ".cache" / "claude-thread-overview" / "channels.json"


def project_of(s):
    return next((t.split(":", 2)[2] for t in s.get("tags") or []
                 if t.startswith("config:hearth-made-for-project:")), None)


def channel_ids(sessions, token, org):
    """Map project UUID (from tags) -> chan_ id. The list API only has the UUID; the per-session
    detail has the chan_ id. Fetch one detail per new project and cache it (the mapping never changes)."""
    try:
        cache = json.loads(CHAN_CACHE.read_text())
    except (OSError, ValueError):
        cache = {}
    changed = False
    for s in sessions:
        pid = project_of(s)
        if not pid or pid in cache:
            continue
        status, body = api_get(f"/v1/code/sessions/{urllib.parse.quote(s.get('id') or '')}", token, org)
        detail = (body or {}).get("response_shape") or body or {}
        chan = detail.get("created_for_hearth_channel_id")
        if status == 200 and chan:
            cache[pid] = chan
            changed = True
    if changed:
        try:
            CHAN_CACHE.parent.mkdir(parents=True, exist_ok=True)
            CHAN_CACHE.write_text(json.dumps(cache, indent=1))
        except OSError:
            pass
    return cache


def links_for(sid, chan):
    """Desktop deep link + web link. Project threads open inside their project's thread pane."""
    if chan:
        path = f"code/project/{chan}?thread={sid}"
    else:
        path = f"code/{sid}"
    return f"claude://claude.ai/{path}", f"https://claude.ai/{path}"


def build_rows(sessions, chans=None):
    chans = chans or {}
    project_names = {}
    for s in sessions:
        tags = s.get("tags") or []
        pid = next((t.split(":", 2)[2] for t in tags if t.startswith("config:hearth-made-for-project:")), None)
        m = COORD_RE.match(s.get("title") or "")
        if pid and m and ("hearth-overview" in tags or "config:hearth-channel-session" in tags):
            project_names[pid] = m.group(1)

    rows = []
    for s in sessions:
        tags = s.get("tags") or []
        if "hearth-overview" in tags or "config:hearth-channel-session" in tags:
            continue  # the project coordinator itself, not a thread
        pid = next((t.split(":", 2)[2] for t in tags if t.startswith("config:hearth-made-for-project:")), None)
        if pid:
            project = project_names.get(pid, f"project {pid[:8]}")
        elif "remote-control-sdk" in tags:
            project = "(Remote Control)"
        else:
            project = "(standalone)"
        needs, recent = summary_of(s)
        updated = parse_time(s.get("updated_at"))
        url, web_url = links_for(s.get("id"), chans.get(pid) if pid else None)
        rows.append({
            "id": s.get("id"),
            "title": s.get("title") or "(untitled)",
            "project": project,
            "state": norm_state(s),
            "archived": "ARCHIVED" in (s.get("session_status") or "").upper(),
            "unread": bool(s.get("unread")),
            "needs_action": needs,
            "recent_action": recent,
            "updated_at": s.get("updated_at"),
            "_updated": updated,
            "url": url,
            "web_url": web_url,
        })
    return rows


CONFIG_PATHS = [
    Path(__file__).with_name("config.json"),
    Path.home() / "dev" / "claude-thread-overview" / "config.json",
]


def load_config():
    """config.json: {"projects": ["Project A", ...]} limits the overview to those projects (case-insensitive).
    Leave "projects" out or empty to show everything."""
    for p in CONFIG_PATHS:
        try:
            cfg = json.loads(p.read_text())
            log("config from", p)
            return cfg
        except (OSError, ValueError):
            continue
    return {}


def select(rows, days, include_archived, projects=None):
    wanted = {x.strip().lower() for x in (projects or []) if x.strip()}
    if wanted:
        rows = [r for r in rows if r["project"].lower() in wanted]
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    keep = []
    for r in rows:
        if r["archived"] and not include_archived:
            continue
        if r["state"] == "completed" and not include_archived and (r["_updated"] or cutoff) < cutoff:
            continue
        keep.append(r)
    keep.sort(key=lambda r: (STATE_ORDER.index(r["state"]),
                             -(r["_updated"].timestamp() if r["_updated"] else 0)))
    return keep


# ---------------------------------------------------------------- output
def print_terminal(rows):
    if not rows:
        print("Nothing open. 🎉")
        return
    bold = "\033[1m" if sys.stdout.isatty() else ""
    dim = "\033[2m" if sys.stdout.isatty() else ""
    reset = "\033[0m" if sys.stdout.isatty() else ""
    pw = min(22, max(len(r["project"]) for r in rows))
    current = None
    for r in rows:
        if r["state"] != current:
            current = r["state"]
            n = sum(1 for x in rows if x["state"] == current)
            print(f"\n{bold}{STATE_LABEL[current]} ({n}){reset}")
        dot = "•" if r["unread"] else " "
        print(f" {dot} {r['project'][:pw]:<{pw}}  {r['title'][:60]:<60}  {dim}{ago(r['_updated'])}{reset}")
        note = r["needs_action"] if r["state"] == "blocked" and r["needs_action"] else r["recent_action"]
        if note:
            print(f"   {'':<{pw}}  {dim}{note[:110]}{reset}")
    print(f"\n{dim}• = unread   open a thread: https://claude.ai/code/<id>   --json for ids{reset}")


def write_html(rows, path):
    groups = []
    for st in STATE_ORDER:
        items = [r for r in rows if r["state"] == st]
        if not items:
            continue
        lis = []
        for r in items:
            note = r["needs_action"] if st == "blocked" and r["needs_action"] else r["recent_action"]
            lis.append(
                f'<li class="{"unread" if r["unread"] else ""}"><a href="{html.escape(r["web_url"])}">'
                f'<span class="proj">{html.escape(r["project"])}</span>'
                f'<span class="title">{html.escape(r["title"])}</span>'
                f'<span class="when">{ago(r["_updated"])}</span></a>'
                + (f'<p>{html.escape(note)}</p>' if note else "") + "</li>")
        groups.append(f'<section class="{st}"><h2>{STATE_LABEL[st]} <small>{len(items)}</small></h2>'
                      f'<ul>{"".join(lis)}</ul></section>')
    now = dt.datetime.now().strftime("%a %d %b, %H:%M")
    doc = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Claude threads</title>
<style>
:root{{--bg:#faf9f7;--fg:#1f1e1c;--mute:#77736c;--line:#e7e3dc;--card:#fff;--accent:#c96442}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1c1b19;--fg:#ecebe8;--mute:#9a968e;--line:#33312d;--card:#262522}}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:900px;margin:auto}}
h1{{font-size:20px;margin:0 0 4px}} .stamp{{color:var(--mute);font-size:13px}}
h2{{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin:28px 0 8px}}
h2 small{{font-weight:400}} section.blocked h2{{color:var(--accent)}}
ul{{list-style:none;margin:0;padding:0;border:1px solid var(--line);border-radius:10px;background:var(--card)}}
li{{padding:10px 14px;border-top:1px solid var(--line)}} li:first-child{{border-top:0}}
li a{{display:flex;gap:12px;color:inherit;text-decoration:none;align-items:baseline}}
li a:hover .title{{text-decoration:underline}}
.proj{{color:var(--mute);font-size:13px;min-width:130px;max-width:130px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.title{{flex:1;font-weight:500}} .when{{color:var(--mute);font-size:13px;white-space:nowrap}}
li.unread .title::before{{content:"● ";color:var(--accent)}}
li p{{margin:4px 0 0 142px;color:var(--mute);font-size:13px}}
@media (max-width:600px){{.proj{{min-width:0;max-width:none}} li a{{flex-wrap:wrap}} li p{{margin-left:0}}}}
</style></head><body><h1>Claude threads</h1><div class="stamp">Updated {now}</div>
{''.join(groups) or '<p>Nothing open.</p>'}</body></html>"""
    path.write_text(doc)
    return path


def main():
    global DEBUG
    ap = argparse.ArgumentParser(description="Overview of Claude Code threads across all projects")
    ap.add_argument("--days", type=int, default=3, help="show finished threads from the last N days (default 3)")
    ap.add_argument("--all", action="store_true", help="include archived/resolved sessions")
    ap.add_argument("--html", action="store_true", help="write overview.html and open it")
    ap.add_argument("--json", action="store_true", help="print normalised rows as JSON")
    ap.add_argument("--projects", help="comma-separated project names to show (overrides config.json)")
    ap.add_argument("--debug", action="store_true")
    a = ap.parse_args()
    DEBUG = a.debug

    token, org = load_credentials()
    log("org uuid found:", bool(org))

    sessions = fetch_sessions(token, org)
    # Project threads may be hidden from the default listing; ask for them by tag as well.
    tagged = fetch_sessions(token, org, tags=["hearth-thread", "hearth-overview"], required=False)
    seen = {s.get("id") for s in sessions}
    sessions += [s for s in tagged if s.get("id") not in seen]
    log("sessions fetched:", len(sessions), "of which tagged hearth:",
        sum(1 for s in sessions if "hearth-thread" in (s.get("tags") or [])))

    projects = a.projects.split(",") if a.projects is not None else load_config().get("projects")
    rows = select(build_rows(sessions, channel_ids(sessions, token, org)), a.days, a.all, projects)
    if a.json:
        print(json.dumps([{k: v for k, v in r.items() if not k.startswith("_")} for r in rows], indent=2))
        return
    print_terminal(rows)
    if a.html:
        p = write_html(rows, Path(__file__).with_name("overview.html"))
        webbrowser.open(p.as_uri())


if __name__ == "__main__":
    main()
