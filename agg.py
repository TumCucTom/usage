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
ACTIVE_SECS = 120            # a session counts as "running" if its transcript was written this recently

# Claude Code does NOT expose rate-limit percentages locally, so Claude usage %
# is computed against these configurable caps (cache-inclusive tokens). Adjust to
# match your plan's real limits if you know them.
CLAUDE_5H_LIMIT = 2_000_000_000
CLAUDE_WEEK_LIMIT = 12_000_000_000

CACHE_VERSION = 8


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
                    recent.append([ep, model, it + ot + cc + cr])
    except Exception:
        return None
    return {
        "provider": "claude", "project": proj,
        "named": title is not None,
        "session_label": title if title else (proj + "·" + os.path.basename(path)[:6]),
        "sessions": sorted(sessions), "last_activity": last_activity,
        "days": days, "recent": recent,
        "codex_rate": None, "codex_rate_ts": None,
    }


def parse_codex_file(path, now):
    proj = "?"
    sid = None
    days = {}
    recent = []
    last_activity = 0.0
    horizon = now - RECENT_RETAIN
    model = "codex"
    rate = None
    rate_ts = None
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
                            recent.append([ep, model, tot])
                    rl = p.get("rate_limits")
                    if isinstance(rl, dict) and ep and (rate_ts is None or ep > rate_ts):
                        rate = rl
                        rate_ts = ep
    except Exception:
        return None
    if sid is None:
        sid = os.path.basename(path)
    return {
        "provider": "codex", "project": proj,
        "named": False,   # Codex has no user-given --resume session names
        "session_label": proj + "·" + str(sid)[:6],
        "sessions": [sid], "last_activity": last_activity,
        "days": days, "recent": recent,
        "codex_rate": rate, "codex_rate_ts": rate_ts,
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
    cut5 = now - 5 * 3600
    cut24 = now - 24 * 3600
    cut7 = now - 7 * 86400
    for c in contribs:
        for s in c["sessions"]:
            sessions.add(c["provider"] + ":" + str(s))
        if c["last_activity"] and c["last_activity"] >= now - LIVE_WINDOW:
            live += 1
        proj_total = 0
        for day, models in c["days"].items():
            for model, v in models.items():
                tot = v[0] + v[1] + v[2] + v[3]   # all tokens incl cache
                life["input"] += v[0]; life["output"] += v[1]
                life["cache_creation"] += v[2]; life["cache_read"] += v[3]
                by_model[model] = by_model.get(model, 0) + tot
                proj_total += tot
                if day == today:
                    day_today["input"] += v[0]; day_today["output"] += v[1]
                    day_today["cache_creation"] += v[2]; day_today["cache_read"] += v[3]
        by_project[c["project"]] = by_project.get(c["project"], 0) + proj_total
        if c.get("named"):   # only sessions with a real --resume name
            lbl = c["session_label"]
            ni = named_info.setdefault(lbl, {"tokens": 0, "last": 0.0})
            ni["tokens"] += proj_total
            ni["last"] = max(ni["last"], c["last_activity"] or 0.0)
        for ep, model, tot in c["recent"]:
            if ep >= cut7:
                w7d += tot
                if ep >= cut24:
                    w24h += tot
                    if ep >= cut5:
                        w5h += tot
    return {
        "lifetime": life,
        "lifetime_total": total_of(life),
        "today": day_today,
        "today_total": total_of(day_today),
        "w5h": w5h, "w24h": w24h, "w7d": w7d,
        "by_model": by_model,
        "by_project": by_project,
        "named_info": named_info,
        "sessions": len(sessions),
        "live": live,
    }


def latest_codex_rate(contribs):
    """Return normalized {five_h, weekly, plan, as_of} mapping each window by
    its window_minutes (slots 'primary'/'secondary' are not positionally fixed)."""
    best = None
    best_ts = -1
    for c in contribs:
        if c.get("codex_rate") and c.get("codex_rate_ts", 0) and c["codex_rate_ts"] > best_ts:
            best = c["codex_rate"]; best_ts = c["codex_rate_ts"]
    if best is None:
        return None
    five_h = weekly = None
    for slot in ("primary", "secondary"):
        w = best.get(slot)
        if not isinstance(w, dict):
            continue
        win = w.get("window_minutes") or 0
        entry = {"used_percent": w.get("used_percent"), "resets_at": w.get("resets_at"),
                 "window_minutes": win}
        if win and win <= 600:          # ~5h window
            five_h = entry
        elif win:                        # weekly (~10080) or other long window
            weekly = entry
    return {"five_h": five_h, "weekly": weekly,
            "plan": best.get("plan_type"), "as_of": best_ts}


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


def live_split(open_n, recent_n):
    running = min(open_n, recent_n)
    return {"open": open_n, "running": running, "idle": max(0, open_n - running)}


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
        "sessions": claude["sessions"] + codex["sessions"],
        "live": claude["live"] + codex["live"],
        "cache_read": claude["lifetime"]["cache_read"] + codex["lifetime"]["cache_read"],
    }
    by_project_all = {}
    for src in (claude, codex):
        for k, v in src["by_project"].items():
            by_project_all[k] = by_project_all.get(k, 0) + v
    resume_names = running_resume_names()
    named_all = {}
    for src in (claude, codex):
        for k, v in src["named_info"].items():
            e = named_all.setdefault(k, {"tokens": 0, "last": 0.0})
            e["tokens"] += v["tokens"]
            e["last"] = max(e["last"], v["last"])
    named_sessions = [
        {"name": k, "tokens": v["tokens"], "last_activity": v["last"],
         "running": k in resume_names}
        for k, v in named_all.items()
    ]
    # keep the 50 most recent so all three UI views (usage/current/recent) have data
    named_sessions.sort(key=lambda s: s["last_activity"], reverse=True)
    named_sessions = named_sessions[:50]

    # live / open sessions (running vs idle) from process + recent-write inspection
    proc = count_open_sessions()
    rc = count_recent_files(claude_files, now, ACTIVE_SECS)
    rx = count_recent_files(codex_files, now, ACTIVE_SECS)
    c_live = live_split(proc["claude_open"], rc)
    x_live = live_split(proc["codex_open"], rx)
    live_sessions = {
        "claude": c_live, "codex": x_live,
        "open": c_live["open"] + x_live["open"],
        "running": c_live["running"] + x_live["running"],
        "idle": c_live["idle"] + x_live["idle"],
        "avail": proc["avail"],
    }

    out = {
        "generated_at": now,
        "claude": {
            **{k: claude[k] for k in ("lifetime_total", "today_total", "w5h", "w24h", "w7d", "sessions", "live")},
            "lifetime_breakdown": claude["lifetime"],
            "top_models": top_n(claude["by_model"]),
            "top_projects": top_n(claude["by_project"]),
            "limits_pct": {
                "five_h": round(100.0 * claude["w5h"] / CLAUDE_5H_LIMIT, 1),
                "weekly": round(100.0 * claude["w7d"] / CLAUDE_WEEK_LIMIT, 1),
                "five_h_limit": CLAUDE_5H_LIMIT,
                "weekly_limit": CLAUDE_WEEK_LIMIT,
            },
        },
        "codex": {
            **{k: codex[k] for k in ("lifetime_total", "today_total", "w5h", "w24h", "w7d", "sessions", "live")},
            "lifetime_breakdown": codex["lifetime"],
            "top_models": top_n(codex["by_model"]),
            "top_projects": top_n(codex["by_project"]),
            "limits": latest_codex_rate(cx),
        },
        "combined": combined,
        "top_projects": top_n(by_project_all, 5),
        "named_sessions": named_sessions,
        "live_sessions": live_sessions,
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
