#!/usr/bin/env python3
"""
Claude Code + Codex usage aggregator.

Scans ~/.claude/projects/**/*.jsonl and ~/.codex/sessions/**/*.jsonl,
aggregates token usage and (for Codex) live rate-limit percentages, and
writes a compact stats.json for the overlay UI to read.

Reading local logs costs ZERO API tokens, so this is safe to run on a timer.

Incremental: each file's contribution is cached keyed by (mtime, size); only
changed/new files are re-parsed, so refreshes stay fast despite GBs of logs.
"""
import json, os, sys, time, glob, subprocess
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude", "projects")
CODEX_DIR = os.path.join(HOME, ".codex", "sessions")

SUPPORT = os.path.join(HOME, "Library", "Application Support", "CCStat")
CACHE_PATH = os.path.join(SUPPORT, "cache.json")
STATS_PATH = os.path.join(SUPPORT, "stats.json")

RECENT_RETAIN = 10 * 86400   # keep per-event points for 10 days (covers 7d window + margin)
LIVE_WINDOW = 15 * 60        # a session is "live" if touched in the last 15 min
ACTIVE_SECS = 120            # a session counts as "running" (actively generating) if written this recently
RUNNING_SECS = 60            # tighter window for the open/running/idle footer split
RATE_RECENCY = 90 * 60       # only trust Codex rate-limit readings this fresh
LIVE_TOLERANCE = 45 * 60     # a named session still counts as "live/idle" if used within this window


def _is_base_limit(e):
    """The base plan rate limit (limit_id 'codex', no descriptive name) rather than
    a model-specific sub-limit like GPT-5.3-Codex-Spark (limit_id 'codex_<model>',
    with a limit_name). Different models put their own limit in the primary slot, so
    concurrent sessions on different models report different limit_ids for the same
    window; the base limit is the one the user thinks of as "my Codex usage"."""
    lid = e.get("limit_id")
    if lid == "codex":
        return True
    return lid is None and not e.get("limit_name")   # older logs had no limit_id


def _rate_beats(new, old):
    """True if reading `new` should replace `old` for the same window key.

    Prefer the base plan limit over a model-specific sub-limit; among readings of the
    same tier, the most recent one wins. Recency alone tracks resets correctly — after
    a reset the newest reading carries the fresh low percentage — so no resets_at
    juggling is needed, and same-limit concurrent sessions agree on current usage."""
    nb, ob = _is_base_limit(new), _is_base_limit(old)
    if nb != ob:
        return nb
    return new["ts"] > old["ts"]

# Claude Code does NOT expose rate-limit percentages locally, so Claude usage %
# is computed against these configurable caps (cache-inclusive tokens). Adjust to
# match your plan's real limits if you know them.
CLAUDE_5H_LIMIT = 2_000_000_000
CLAUDE_WEEK_LIMIT = 12_000_000_000

CACHE_VERSION = 12


# ---------- helpers ----------

def parse_ts(s):
    """ISO-8601 (with trailing Z) -> epoch seconds, or None."""
    if not s or not isinstance(s, str):
        return None
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def local_day(epoch):
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")


def add4(dst, key, vals):
    a = dst.get(key)
    if a is None:
        dst[key] = list(vals)
    else:
        for i in range(4):
            a[i] += vals[i]


# ---------- per-file parsers ----------
# Each returns a compact "contribution" dict:
#   { provider, project, sessions:[...], last_activity:epoch,
#     days:{ "YYYY-MM-DD": { model:[in,out,cache_creation,cache_read] } },
#     recent:[ [epoch, model, total_tokens], ... ]   # last RECENT_RETAIN secs only
#     codex_rate: {..} | None,  codex_rate_ts: epoch | None }


def parse_claude_file(path, now):
    project = os.path.basename(os.path.dirname(path))
    # strip the leading path-mangled prefix Claude uses, keep a friendly tail
    proj = project.lstrip("-").split("-")[-1] if project else "?"
    days = {}
    recent = []
    sessions = set()
    last_activity = 0.0
    horizon = now - RECENT_RETAIN
    title = None
    try:
        with open(path, "r", errors="ignore") as fh:
            for line in fh:
                # capture the real --resume name the user gave (custom-title)
                if '"custom-title"' in line or '"agent-name"' in line:
                    try:
                        j = json.loads(line)
                        t = j.get("customTitle") or j.get("agentName")
                        if t:
                            title = t.strip()
                    except Exception:
                        pass
                    continue
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "assistant":
                    continue
                msg = d.get("message") or {}
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue
                model = msg.get("model") or "unknown"
                if model in ("<synthetic>", "synthetic"):
                    continue
                it = usage.get("input_tokens", 0) or 0
                ot = usage.get("output_tokens", 0) or 0
                cc = usage.get("cache_creation_input_tokens", 0) or 0
                cr = usage.get("cache_read_input_tokens", 0) or 0
                if not (it or ot or cc or cr):
                    continue
                ep = parse_ts(d.get("timestamp")) or 0.0
                sid = d.get("sessionId")
                if sid:
                    sessions.add(sid)
                if ep > last_activity:
                    last_activity = ep
                day = local_day(ep) if ep else "unknown"
                dd = days.setdefault(day, {})
                add4(dd, model, (it, ot, cc, cr))
                if ep >= horizon:
                    recent.append([ep, model, it + ot + cc + cr, it + ot])
    except Exception:
        return None
    return {
        "provider": "claude", "project": proj, "path": path,
        "named": title is not None,
        "session_label": title if title else (proj + "·" + os.path.basename(path)[:6]),
        "sessions": sorted(sessions), "last_activity": last_activity,
        "days": days, "recent": recent,
        "codex_rate": None,
    }


def parse_codex_file(path, now):
    proj = "?"
    sid = None
    days = {}
    recent = []
    last_activity = 0.0
    horizon = now - RECENT_RETAIN
    model = "codex"
    best_win = {}   # window key -> highest recent rate-limit reading
    try:
        with open(path, "r", errors="ignore") as fh:
            for line in fh:
                if ('token_count' not in line and '"cwd"' not in line
                        and '"model"' not in line):
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                p = d.get("payload")
                if not isinstance(p, dict):
                    continue
                if p.get("cwd"):
                    proj = os.path.basename(p["cwd"]) or proj
                if p.get("session_id") and sid is None:
                    sid = p["session_id"]
                if p.get("model"):
                    model = p["model"]
                if p.get("type") == "token_count":
                    info = p.get("info") or {}
                    last = info.get("last_token_usage") or {}
                    tot = last.get("total_tokens", 0) or 0
                    it = last.get("input_tokens", 0) or 0
                    ot = last.get("output_tokens", 0) or 0
                    ro = last.get("reasoning_output_tokens", 0) or 0
                    cin = last.get("cached_input_tokens", 0) or 0
                    nc_in = it - cin if it > cin else 0   # exclude cached input reads
                    ep = parse_ts(d.get("timestamp")) or 0.0
                    if ep > last_activity:
                        last_activity = ep
                    if tot:
                        day = local_day(ep) if ep else "unknown"
                        dd = days.setdefault(day, {})
                        # slots [fresh input, output, 0, cached-read]; sum == total_tokens
                        out = tot - it if tot > it else ot   # exact output, avoids reasoning double-count
                        add4(dd, model, (nc_in, out, 0, cin))
                        if ep >= horizon:
                            recent.append([ep, model, tot, max(0, tot - cin)])
                    rl = p.get("rate_limits")
                    if isinstance(rl, dict) and ep and ep >= now - RATE_RECENCY:
                        for slot in ("primary", "secondary"):
                            w = rl.get(slot)
                            if not isinstance(w, dict) or w.get("used_percent") is None:
                                continue
                            win = w.get("window_minutes") or 0
                            key = "five_h" if 0 < win <= 600 else ("weekly" if win else None)
                            if not key:
                                continue
                            up = w["used_percent"]
                            ra = w.get("resets_at")
                            # skip readings whose window has already reset — the
                            # percentage describes an expired window and is stale.
                            if ra is not None and ra <= now:
                                continue
                            cand = {"used_percent": up, "resets_at": ra,
                                    "window_minutes": win, "ts": ep,
                                    "plan": rl.get("plan_type"),
                                    "limit_id": w.get("limit_id") or rl.get("limit_id"),
                                    "limit_name": w.get("limit_name") or rl.get("limit_name")}
                            cur = best_win.get(key)
                            # newest window wins; ties within a window keep the real usage
                            if cur is None or _rate_beats(cand, cur):
                                best_win[key] = cand
    except Exception:
        return None
    if sid is None:
        sid = os.path.basename(path)
    return {
        "provider": "codex", "project": proj, "path": path,
        "named": False,   # Codex has no user-given --resume session names
        "session_label": proj + "·" + str(sid)[:6],
        "sessions": [sid], "last_activity": last_activity,
        "days": days, "recent": recent,
        "codex_rate": best_win or None,
    }


# ---------- scan with cache ----------

def scan(files, parser, cache, now):
    contribs = []
    for path in files:
        try:
            st = os.stat(path)
        except OSError:
            continue
        key = path
        ent = cache.get(key)
        if ent and ent.get("mtime") == st.st_mtime and ent.get("size") == st.st_size:
            contribs.append(ent["c"])
            continue
        c = parser(path, now)
        if c is None:
            continue
        cache[key] = {"mtime": st.st_mtime, "size": st.st_size, "c": c}
        contribs.append(c)
    return contribs


# ---------- aggregation ----------

def blank():
    return {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}


def total_of(b):
    # all tokens processed, including cache creation + cache reads
    return b["input"] + b["output"] + b["cache_creation"] + b["cache_read"]


def nocache_of(b):
    # generation tokens only (input + output), excluding cache
    return b["input"] + b["output"]


def agg_provider(contribs, now):
    today = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    life = blank()
    day_today = blank()
    by_model = {}
    by_project = {}
    named_info = {}   # --resume name -> {"tokens", "last"}
    sessions = set()
    live = 0
    w5h = w24h = w7d = 0
    w5h_nc = w24h_nc = w7d_nc = 0
    cut5 = now - 5 * 3600
    cut24 = now - 24 * 3600
    cut7 = now - 7 * 86400
    for c in contribs:
        for s in c["sessions"]:
            sessions.add(c["provider"] + ":" + str(s))
        if c["last_activity"] and c["last_activity"] >= now - LIVE_WINDOW:
            live += 1
        proj_total = 0
        proj_nc = 0
        for day, models in c["days"].items():
            for model, v in models.items():
                tot = v[0] + v[1] + v[2] + v[3]   # all tokens incl cache
                nc = v[0] + v[1]                  # non-cache (input+output)
                life["input"] += v[0]; life["output"] += v[1]
                life["cache_creation"] += v[2]; life["cache_read"] += v[3]
                by_model[model] = by_model.get(model, 0) + tot
                proj_total += tot
                proj_nc += nc
                if day == today:
                    day_today["input"] += v[0]; day_today["output"] += v[1]
                    day_today["cache_creation"] += v[2]; day_today["cache_read"] += v[3]
        by_project[c["project"]] = by_project.get(c["project"], 0) + proj_total
        # Claude: only sessions the user gave a --resume name (filters out ephemeral
        # sub-agent transcripts). Codex has no --resume names but every file is a real
        # session, so include all of them keyed by their proj·<sid> label.
        if c.get("named") or c["provider"] == "codex":
            lbl = c["session_label"]
            ni = named_info.setdefault(lbl, {"tokens": 0, "tokens_nc": 0, "last": 0.0, "paths": []})
            ni["tokens"] += proj_total
            ni["tokens_nc"] += proj_nc
            ni["last"] = max(ni["last"], c["last_activity"] or 0.0)
            if c.get("path"):
                ni["paths"].append(c["path"])
        for ev in c["recent"]:
            ep, tot = ev[0], ev[2]
            nc = ev[3] if len(ev) > 3 else tot
            if ep >= cut7:
                w7d += tot; w7d_nc += nc
                if ep >= cut24:
                    w24h += tot; w24h_nc += nc
                    if ep >= cut5:
                        w5h += tot; w5h_nc += nc
    return {
        "lifetime": life,
        "lifetime_total": total_of(life),
        "lifetime_nc": nocache_of(life),
        "today": day_today,
        "today_total": total_of(day_today),
        "today_nc": nocache_of(day_today),
        "w5h": w5h, "w24h": w24h, "w7d": w7d,
        "w5h_nc": w5h_nc, "w24h_nc": w24h_nc, "w7d_nc": w7d_nc,
        "by_model": by_model,
        "by_project": by_project,
        "named_info": named_info,
        "sessions": len(sessions),
        "live": live,
    }


def latest_codex_rate(contribs, now):
    """Aggregate the highest recent reading per window across all Codex sessions.
    Concurrent sessions report conflicting values (plan vs API-key contexts, some 0%),
    so the max recent reading reflects real plan usage; 0% noise is ignored.
    Readings whose window has already reset are dropped so a limit reset shows
    immediately instead of being held at the stale pre-reset percentage."""
    agg = {}
    for c in contribs:
        br = c.get("codex_rate")
        if not isinstance(br, dict):
            continue
        for key, e in br.items():
            ra = e.get("resets_at")
            if ra is not None and ra <= now:
                continue
            cur = agg.get(key)
            if cur is None or _rate_beats(e, cur):
                agg[key] = e
    if not agg:
        return None

    def out(e):
        if not e:
            return None
        return {"used_percent": e["used_percent"], "resets_at": e.get("resets_at"),
                "window_minutes": e.get("window_minutes")}

    plan = next((e.get("plan") for e in agg.values() if e.get("plan")), None)
    as_of = max((e["ts"] for e in agg.values()), default=None)
    return {"five_h": out(agg.get("five_h")), "weekly": out(agg.get("weekly")),
            "plan": plan, "as_of": as_of}


def top_n(d, n=4):
    items = sorted(d.items(), key=lambda kv: kv[1], reverse=True)
    return [{"name": k, "tokens": v} for k, v in items[:n] if v > 0]


# ---------- live / open sessions (process inspection) ----------

def count_open_sessions():
    """Count interactive Claude Code + Codex CLI sessions currently running.
    Excludes background infrastructure (daemons, pty hosts, app-servers, GUI helpers)."""
    try:
        out = subprocess.run(["ps", "-axo", "pid,command"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return {"claude_open": 0, "codex_open": 0, "avail": False}
    claude_open = 0
    codex_open = 0
    CLAUDE_SKIP = ("bg-pty-host", "bg-spare", "daemon", "--bg", "bg-host",
                   "Claude.app", "CCStat", "mcp", "--type=")
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        cmd = parts[1]
        # Claude interactive CLI: basename 'claude ...' without infra keywords
        if cmd == "claude" or cmd.startswith("claude ") or cmd.startswith("claude\t"):
            if not any(k in cmd for k in CLAUDE_SKIP):
                claude_open += 1
        # Codex interactive TUI: the bare `codex` process (not app-server / host / GUI)
        elif cmd.strip() == "codex":
            codex_open += 1
    return {"claude_open": claude_open, "codex_open": codex_open, "avail": True}


def _dbg(msg):
    try:
        with open(os.path.join(SUPPORT, "claude_debug.txt"), "w") as f:
            f.write(str(msg))
    except Exception:
        pass


USAGE_TTL = 900   # re-fetch /usage at most every 15 min; it's strict-rate-limited (Claude Code calls it on-demand, not on a timer)


def claude_usage():
    """Cached real Claude usage. Fetches /usage at most every USAGE_TTL seconds and
    reuses the last good value on 429/offline (so the display never drops to the
    estimate just because a poll was rate-limited)."""
    cache_path = os.path.join(SUPPORT, "usage_cache.json")
    cached = None
    try:
        cached = json.load(open(cache_path))
    except Exception:
        cached = None
    now = time.time()
    if cached and (now - cached.get("ts", 0)) < USAGE_TTL:
        return cached.get("result")
    result = _fetch_claude_usage()
    prev = cached.get("result") if cached else None
    to_store = result if result is not None else prev   # keep last good on failure
    # always stamp ts so failed fetches are throttled too (don't re-trip the rate limit)
    try:
        json.dump({"ts": now, "result": to_store}, open(cache_path, "w"))
    except Exception:
        pass
    return to_store


def _fetch_claude_usage():
    """Fetch REAL Claude usage from the same endpoint /usage uses, authenticated
    with the OAuth token in the login Keychain. Metadata endpoint — no token cost."""
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5)
        raw = r.stdout
        if not raw.strip():
            _dbg("no token stdout; rc=%s stderr=%s" % (r.returncode, r.stderr[:200]))
            return None
        tok = (json.loads(raw).get("claudeAiOauth") or {}).get("accessToken")
        if not tok:
            _dbg("token parse failed")
            return None
        import urllib.request
        req = urllib.request.Request(
            "https://api.anthropic.com/api/oauth/usage",
            headers={"Authorization": "Bearer " + tok,
                     "anthropic-beta": "oauth-2025-04-20",
                     "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            d = json.loads(resp.read().decode())
        _dbg("OK")
    except Exception as e:
        _dbg("exception: %r" % e)
        return None

    def win(o):
        if not isinstance(o, dict) or o.get("utilization") is None:
            return None
        return {"used_percent": round(float(o["utilization"]), 1),
                "resets_at": parse_ts(o.get("resets_at"))}

    fh, sd = win(d.get("five_hour")), win(d.get("seven_day"))
    if fh is None and sd is None:
        return None
    # per-model scoped weekly limit for Fable, from the limits[] array
    fable = None
    for lm in d.get("limits") or []:
        sc = lm.get("scope") or {}
        mdl = sc.get("model") or {} if isinstance(sc, dict) else {}
        if isinstance(mdl, dict) and (mdl.get("display_name") or "").lower() == "fable":
            fable = {"used_percent": round(float(lm.get("percent") or 0), 1),
                     "resets_at": parse_ts(lm.get("resets_at"))}
            break
    return {"five_h": fh, "weekly": sd, "fable": fable, "ok": True}


def memory_stats():
    """macOS memory breakdown (Activity Monitor-style), values in bytes."""
    import re
    def sh(c):
        try:
            return subprocess.run(c, capture_output=True, text=True, timeout=4).stdout
        except Exception:
            return ""
    try:
        pagesize = int(sh(["sysctl", "-n", "hw.pagesize"]) or 16384)
        physical = int(sh(["sysctl", "-n", "hw.memsize"]) or 0)
    except Exception:
        return None
    if not physical:
        return None
    vm = sh(["vm_stat"])
    def pages(label):
        m = re.search(re.escape(label) + r':\s+(\d+)\.', vm)
        return int(m.group(1)) if m else 0
    wired = pages("Pages wired down") * pagesize
    comp = pages("Pages occupied by compressor") * pagesize
    anon = pages("Anonymous pages") * pagesize
    purg = pages("Pages purgeable") * pagesize
    fileb = pages("File-backed pages") * pagesize
    app = max(0, anon - purg)
    cached = fileb + purg
    used = app + wired + comp
    swu = 0.0
    m = re.search(r'used = ([0-9.]+)([KMG])', sh(["sysctl", "-n", "vm.swapusage"]))
    if m:
        swu = float(m.group(1)) * {"K": 1024, "M": 1024**2, "G": 1024**3}[m.group(2)]
    lvl = sh(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    level = {"1": "normal", "2": "warning", "4": "critical"}.get(lvl, "normal")
    return {"physical": physical, "used": used, "cached": cached, "swap": swu,
            "app": app, "wired": wired, "compressed": comp,
            "pressure_pct": round(100.0 * (wired + comp) / physical, 1), "level": level}


def running_resume_names():
    """Names currently open via `claude --resume <name>` processes."""
    try:
        out = subprocess.run(["ps", "-axo", "command"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return set()
    names = set()
    marker = "--resume "
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("claude"):
            continue
        i = line.find(marker)
        if i >= 0:
            name = line[i + len(marker):].strip().strip('"').strip("'")
            if name:
                names.add(name)
    return names


def lsof_open_transcripts():
    """Transcript files currently held open by a running claude/codex process."""
    try:
        out = subprocess.run(["lsof", "-c", "claude", "-c", "codex"],
                             capture_output=True, text=True, timeout=6).stdout
    except Exception:
        return set()
    open_paths = set()
    for line in out.splitlines():
        j = line.find("/")
        if j < 0:
            continue
        p = line[j:].strip()
        if p.endswith(".jsonl") and ("/.claude/projects/" in p or "/.codex/sessions/" in p):
            open_paths.add(p)
    return open_paths


def count_recent_files(files, now, secs):
    n = 0
    cut = now - secs
    for p in files:
        try:
            if os.stat(p).st_mtime >= cut:
                n += 1
        except OSError:
            pass
    return n


def _pid_cwd(pid):
    try:
        o = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
                           capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return None
    for ln in o.splitlines():
        if ln.startswith("n"):
            return ln[1:]
    return None


def _recent_in_dir(cwd, now):
    """How many transcripts in the project dir for `cwd` were written recently."""
    if not cwd:
        return 0
    d = os.path.join(CLAUDE_DIR, cwd.replace("/", "-").replace(".", "-"))
    cut = now - RUNNING_SECS
    n = 0
    for f in glob.glob(os.path.join(d, "*.jsonl")):
        try:
            if os.stat(f).st_mtime >= cut:
                n += 1
        except OSError:
            pass
    return n


def live_session_counts(now, open_files):
    """Accurate open/running/idle for interactive CLI sessions.
    Claude: group open PIDs by cwd, running = min(#pids, #recent transcripts) per dir
    (handles many sessions sharing one directory). Codex: each PID holds its own
    transcript open, so running = recent among those."""
    SKIP = ("bg-pty-host", "bg-spare", "daemon", "--bg", "bg-host",
            "Claude.app", "CCStat", "mcp", "--type=")
    try:
        out = subprocess.run(["ps", "-axo", "pid,command"], capture_output=True,
                             text=True, timeout=5).stdout
    except Exception:
        return None
    claude_pids, codex_pids = [], []
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, cmd = parts[0], parts[1]
        if cmd == "claude" or cmd.startswith("claude "):
            if not any(k in cmd for k in SKIP):
                claude_pids.append(pid)
        elif cmd.strip() == "codex":
            codex_pids.append(pid)

    cwd_pids = {}
    for pid in claude_pids:
        cwd = _pid_cwd(pid) or ""
        cwd_pids[cwd] = cwd_pids.get(cwd, 0) + 1
    c_run = 0
    for cwd, npids in cwd_pids.items():
        c_run += min(npids, _recent_in_dir(cwd, now))
    c_open = len(claude_pids)
    c = {"open": c_open, "running": c_run, "idle": max(0, c_open - c_run)}

    x_recent = 0
    cut = now - RUNNING_SECS
    for f in open_files:
        if "/.codex/sessions/" in f:
            try:
                if os.stat(f).st_mtime >= cut:
                    x_recent += 1
            except OSError:
                pass
    x_open = len(codex_pids)
    x_run = min(x_open, x_recent)
    x = {"open": x_open, "running": x_run, "idle": max(0, x_open - x_run)}

    return {"claude": c, "codex": x,
            "open": c["open"] + x["open"], "running": c["running"] + x["running"],
            "idle": c["idle"] + x["idle"], "avail": True}


# ---------- main ----------

def main():
    os.makedirs(SUPPORT, exist_ok=True)
    now = time.time()
    cache = {}
    if os.path.exists(CACHE_PATH):
        try:
            raw = json.load(open(CACHE_PATH))
            if raw.get("v") == CACHE_VERSION:
                cache = raw.get("files", {})
        except Exception:
            cache = {}

    claude_files = glob.glob(os.path.join(CLAUDE_DIR, "**", "*.jsonl"), recursive=True)
    codex_files = glob.glob(os.path.join(CODEX_DIR, "**", "*.jsonl"), recursive=True)

    cc = scan(claude_files, parse_claude_file, cache, now)
    cx = scan(codex_files, parse_codex_file, cache, now)

    # rebuild cache from only files that still exist (drop deleted)
    live_keys = set(claude_files) | set(codex_files)
    new_cache = {k: v for k, v in cache.items() if k in live_keys}

    claude = agg_provider(cc, now)
    codex = agg_provider(cx, now)

    combined = {
        "lifetime_total": claude["lifetime_total"] + codex["lifetime_total"],
        "today_total": claude["today_total"] + codex["today_total"],
        "w5h": claude["w5h"] + codex["w5h"],
        "w24h": claude["w24h"] + codex["w24h"],
        "w7d": claude["w7d"] + codex["w7d"],
        "lifetime_nc": claude["lifetime_nc"] + codex["lifetime_nc"],
        "today_nc": claude["today_nc"] + codex["today_nc"],
        "w5h_nc": claude["w5h_nc"] + codex["w5h_nc"],
        "w24h_nc": claude["w24h_nc"] + codex["w24h_nc"],
        "w7d_nc": claude["w7d_nc"] + codex["w7d_nc"],
        "sessions": claude["sessions"] + codex["sessions"],
        "live": claude["live"] + codex["live"],
        "cache_read": claude["lifetime"]["cache_read"] + codex["lifetime"]["cache_read"],
    }
    by_project_all = {}
    for src in (claude, codex):
        for k, v in src["by_project"].items():
            by_project_all[k] = by_project_all.get(k, 0) + v
    resume_names = running_resume_names()
    open_files = lsof_open_transcripts()
    named_all = {}
    for src in (claude, codex):
        for k, v in src["named_info"].items():
            e = named_all.setdefault(k, {"tokens": 0, "tokens_nc": 0, "last": 0.0, "paths": []})
            e["tokens"] += v["tokens"]
            e["tokens_nc"] += v.get("tokens_nc", 0)
            e["last"] = max(e["last"], v["last"])
            e["paths"].extend(v.get("paths", []))
    named_sessions = []
    for k, v in named_all.items():
        running = v["last"] >= now - ACTIVE_SECS       # actively generating
        # live = process open (by --resume name or held-open transcript) OR recently used
        live = (k in resume_names
                or any(p in open_files for p in v["paths"])
                or v["last"] >= now - LIVE_TOLERANCE)
        named_sessions.append({
            "name": k, "tokens": v["tokens"], "tokens_nc": v["tokens_nc"],
            "last_activity": v["last"], "running": running, "live": live,
        })
    # keep the 50 most recent so all three UI views (usage/live/recent) have data
    named_sessions.sort(key=lambda s: s["last_activity"], reverse=True)
    named_sessions = named_sessions[:50]

    # live / open sessions (running vs idle) — per-process, mapped to transcripts
    live_sessions = live_session_counts(now, open_files) or {
        "claude": {"open": 0, "running": 0, "idle": 0},
        "codex": {"open": 0, "running": 0, "idle": 0},
        "open": 0, "running": 0, "idle": 0, "avail": False,
    }

    out = {
        "generated_at": now,
        "claude": {
            **{k: claude[k] for k in ("lifetime_total", "today_total", "w5h", "w24h", "w7d",
                                      "lifetime_nc", "today_nc", "w5h_nc", "w24h_nc", "w7d_nc",
                                      "sessions", "live")},
            "lifetime_breakdown": claude["lifetime"],
            "top_models": top_n(claude["by_model"]),
            "top_projects": top_n(claude["by_project"]),
            "limits_pct": {
                "five_h": round(100.0 * claude["w5h"] / CLAUDE_5H_LIMIT, 1),
                "weekly": round(100.0 * claude["w7d"] / CLAUDE_WEEK_LIMIT, 1),
                "five_h_limit": CLAUDE_5H_LIMIT,
                "weekly_limit": CLAUDE_WEEK_LIMIT,
            },
            "real_limits": claude_usage(),
        },
        "codex": {
            **{k: codex[k] for k in ("lifetime_total", "today_total", "w5h", "w24h", "w7d",
                                     "lifetime_nc", "today_nc", "w5h_nc", "w24h_nc", "w7d_nc",
                                     "sessions", "live")},
            "lifetime_breakdown": codex["lifetime"],
            "top_models": top_n(codex["by_model"]),
            "top_projects": top_n(codex["by_project"]),
            "limits": latest_codex_rate(cx, now),
        },
        "combined": combined,
        "top_projects": top_n(by_project_all, 5),
        "named_sessions": named_sessions,
        "live_sessions": live_sessions,
        "memory": memory_stats(),
    }

    tmp = STATS_PATH + ".tmp"
    json.dump(out, open(tmp, "w"))
    os.replace(tmp, STATS_PATH)
    json.dump({"v": CACHE_VERSION, "files": new_cache}, open(CACHE_PATH, "w"))
    return out


if __name__ == "__main__":
    o = main()
    if "--print" in sys.argv:
        print(json.dumps(o, indent=2, default=str))
