#!/usr/bin/env python3
"""Mock Tauri backend for running the real Flo State frontend in Chrome.

Serves the built frontend ($WRITER_REPO/apps/desktop/dist) with a shim
injected that routes `__TAURI_INTERNALS__.invoke` to POST /ipc here. Every
filesystem command operates on the sandbox workspace ($ORACLE_SANDBOX, default
oracle/sandbox/Sample from make_sandbox.py), never on real notes. Settings are
the schema defaults, overlaid with the local writer-computer config if present
(set FLO_DEFAULT_SETTINGS=1 to ignore it).
"""
import json
import mimetypes
import os
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from paths import DIST, SCHEMA, SANDBOX, ensure_sandbox  # noqa: E402
USER_CONFIG = Path.home() / "Library/Application Support/com.writer-computer/config"
PORT = int(os.environ.get("FLO_ORACLE_PORT", "5288"))
SUPPORTED = (".md", ".mdx", ".markdown", ".txt", ".csv")

STATE = {"sessions": {}, "settings_overrides": {}, "unknown": set(), "log": []}


def parse_config_value(raw):
    raw = raw.strip()
    if raw in ("true", "false"):
        return raw == "true"
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    if len(raw) >= 2 and raw[0] == raw[-1] == '"' and raw.count('"') == 2:
        return raw[1:-1]
    return raw


def load_settings():
    schema = json.loads(SCHEMA.read_text())
    merged = {s["key"]: s.get("default") for s in schema["settings"]}
    if USER_CONFIG.exists() and os.environ.get("FLO_DEFAULT_SETTINGS") != "1":
        multi = {}
        for line in USER_CONFIG.read_text().splitlines():
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            multi.setdefault(k.strip(), []).append(parse_config_value(v))
        for k, vs in multi.items():
            merged[k] = vs if len(vs) > 1 else vs[0]
    merged.update(STATE["settings_overrides"])
    return merged


def mtime(p):
    try:
        return int(p.stat().st_mtime * 1000)
    except OSError:
        return 0


def extract_title(p):
    try:
        text = p.open("rb").read(4096).decode("utf-8", "ignore")
    except OSError:
        return None
    if text.startswith("---\n") or text.startswith("---\r\n"):
        rest = text.split("\n", 1)[1]
        end = rest.find("\n---\n")
        if end >= 0:
            for line in rest[:end].splitlines():
                t = line.strip()
                if t.startswith("title:"):
                    v = t[6:].strip().strip('"').strip("'")
                    if v:
                        return v
            text = rest[end + 5 :]
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip() or None
        if s:
            break
    return None


def dir_contains_md(d):
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        if any(f.lower().endswith(SUPPORTED) for f in files):
            return True
    return False


def dir_entry(p):
    is_dir = p.is_dir()
    return {
        "name": p.name,
        "path": str(p),
        "is_dir": is_dir,
        "is_markdown": (not is_dir) and p.name.lower().endswith(SUPPORTED),
        "modified_at": mtime(p),
        "title": None if is_dir else extract_title(p),
    }


def read_directory(path):
    d = Path(path)
    dirs, files = [], []
    for e in d.iterdir():
        if e.name.startswith("."):
            continue
        if e.is_dir():
            if dir_contains_md(e):
                dirs.append(dir_entry(e))
        elif e.name.lower().endswith(SUPPORTED):
            files.append(dir_entry(e))
    dirs.sort(key=lambda x: x["name"].lower())
    files.sort(key=lambda x: x["name"].lower())
    return dirs + files


def within_sandbox(path):
    p = Path(path).resolve()
    if SANDBOX not in p.parents and p != SANDBOX:
        raise PermissionError(f"outside sandbox: {path}")
    return p


def file_content(path):
    p = within_sandbox(path)
    return {"path": str(p), "content": p.read_text(), "modified_at": mtime(p)}


def workspace_info():
    count = sum(1 for _ in SANDBOX.rglob("*") if _.suffix.lower() in SUPPORTED)
    return {"root": str(SANDBOX), "name": SANDBOX.name, "file_count": count}


def restore_bundle(path):
    session = STATE["sessions"].get(path)
    active = None
    if session and session.get("tabs"):
        idx = session.get("active_index") or 0
        tabs = session["tabs"]
        if 0 <= idx < len(tabs) and tabs[idx]["location"].get("kind") == "file":
            try:
                active = file_content(tabs[idx]["location"]["path"])
            except Exception:
                active = None
    return {
        "workspace": workspace_info(),
        "entries": read_directory(path),
        "recent_workspaces": [str(SANDBOX)],
        "session": session,
        "active_file": active,
        "open_file": None,
    }


def handle(cmd, a):
    root = str(SANDBOX)
    if cmd == "get_startup_state":
        return {
            "settings": load_settings(),
            "recent_workspaces": [root],
            "restore_bundle": restore_bundle(root),
            "standalone_file": None,
        }
    if cmd in ("restore_workspace", "open_workspace"):
        return restore_bundle(a["path"]) if cmd == "restore_workspace" else workspace_info()
    if cmd == "read_directory":
        return read_directory(a["path"])
    if cmd == "read_file":
        return file_content(a["path"])
    if cmd == "write_file":
        p = within_sandbox(a["path"])
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(a["content"])
        return {"path": str(p), "modified_at": mtime(p)}
    if cmd == "create_file":
        p = within_sandbox(a["path"])
        if not p.exists():
            p.write_text("# ")
        return file_content(str(p))
    if cmd == "create_directory":
        p = within_sandbox(a["path"])
        p.mkdir(parents=True, exist_ok=True)
        return dir_entry(p)
    if cmd == "rename_entry":
        within_sandbox(a["oldPath"]).rename(within_sandbox(a["newPath"]))
        return None
    if cmd == "delete_entry":
        p = within_sandbox(a["path"])
        if p.is_dir():
            import shutil
            shutil.rmtree(p)
        else:
            p.unlink()
        return None
    if cmd == "file_exists":
        return Path(a["path"]).exists()
    if cmd == "read_file_entries":
        return [dir_entry(Path(p)) for p in a["paths"] if Path(p).exists()]
    if cmd == "read_recent_files":
        files = sorted(
            (p for p in SANDBOX.rglob("*") if p.suffix.lower() in SUPPORTED),
            key=mtime, reverse=True)
        return [dir_entry(p) for p in files[a.get("offset", 0): a.get("offset", 0) + a.get("limit", 20)]]
    if cmd == "get_recent_files_global":
        files = sorted((p for p in SANDBOX.rglob("*.md")), key=mtime, reverse=True)[: a.get("limit") or 20]
        return [{"path": str(p), "name": p.name, "title": extract_title(p), "opened_at": int(time.time())} for p in files]
    if cmd == "find_file_by_name":
        hits = [p for p in Path(a["root"]).rglob("*") if p.name.lower() == a["fileName"].lower()]
        hits.sort(key=lambda p: len(str(p)))
        return str(hits[0]) if hits else None
    if cmd == "save_session":
        STATE["sessions"][a["workspaceRoot"]] = {"tabs": a["tabs"], "active_index": a["activeIndex"]}
        return None
    if cmd == "load_session":
        return STATE["sessions"].get(a["workspaceRoot"])
    if cmd == "get_recent_workspaces":
        return [root]
    if cmd == "get_settings":
        return load_settings()
    if cmd == "get_setting":
        return load_settings().get(a["key"])
    if cmd == "set_setting":
        STATE["settings_overrides"][a["key"]] = a["value"]
        return None
    if cmd == "reset_setting":
        STATE["settings_overrides"].pop(a["key"], None)
        return None
    if cmd == "index_workspace":
        return {"file_count": workspace_info()["file_count"], "duration_ms": 1}
    if cmd == "fuzzy_search":
        q = (a.get("query") or "").lower()
        out = []
        for p in SANDBOX.rglob("*"):
            if p.suffix.lower() in SUPPORTED and q in p.name.lower():
                out.append({"path": str(p), "filename": p.name,
                            "relative_path": str(p.relative_to(SANDBOX)), "score": 1, "match_indices": []})
        return out[: a.get("limit") or 50]
    if cmd == "list_system_fonts":
        return ["Proxima Nova", "SF Pro", "Helvetica", "Menlo"]
    if cmd in ("take_pending_open", "record_recent_file", "remove_recent_file",
               "remove_recent_workspace", "watch_standalone_file", "reveal_in_file_manager",
               "open_workspace_in_new_window", "open_file_in_standalone_window"):
        return None
    if cmd == "save_clipboard_image":
        md = within_sandbox(a["markdownFilePath"])
        att = md.parent / "attachments"
        att.mkdir(exist_ok=True)
        name = f"pasted-{int(time.time()*1000)}.{a['format']}"
        (att / name).write_bytes(bytes(a["imageData"]))
        return {"relative_path": f"attachments/{name}", "absolute_path": str(att / name)}
    # Tauri plugins
    if cmd == "plugin:event|listen":
        return len(STATE["log"]) + 1000
    if cmd.startswith("plugin:window|") or cmd.startswith("plugin:webview|"):
        name = cmd.split("|", 1)[1]
        if name in ("inner_size", "outer_size"):
            return {"width": 1400, "height": 900}
        if name in ("inner_position", "outer_position"):
            return {"x": 0, "y": 0}
        if name == "scale_factor":
            return 2
        if name.startswith("is_"):
            return name in ("is_visible", "is_focused", "is_resizable")
        return None
    if cmd.startswith("plugin:menu|"):
        return [int(time.time() * 1000) % 100000, "menu"]
    if cmd.startswith("plugin:clipboard-manager|read"):
        return STATE.get("clipboard", "")
    if cmd.startswith("plugin:clipboard-manager|write"):
        STATE["clipboard"] = a.get("text", "")
        return None
    if cmd.startswith("plugin:"):
        return None
    STATE["unknown"].add(cmd)
    return None


SHIM = r"""
(() => {
  const callbacks = new Map();
  let nextId = 1;
  const listeners = {};
  window.__floIpcLog = [];
  window.__TAURI_INTERNALS__ = {
    metadata: { currentWindow: { label: "main" }, currentWebview: { windowLabel: "main", label: "main" } },
    plugins: {},
    transformCallback(cb, once) {
      const id = nextId++;
      callbacks.set(id, (...args) => { if (once) callbacks.delete(id); return cb && cb(...args); });
      return id;
    },
    unregisterCallback(id) { callbacks.delete(id); },
    runCallback(id, data) { const cb = callbacks.get(id); if (cb) cb(data); },
    callbacks,
    convertFileSrc(path) { return "/__asset?path=" + encodeURIComponent(path); },
    async invoke(cmd, args, options) {
      if (cmd === "plugin:event|listen") {
        (listeners[args.event] ||= []).push(args.handler);
      }
      window.__floIpcLog.push(cmd);
      const r = await fetch("/__ipc", { method: "POST", body: JSON.stringify({ cmd, args: args || {} }) });
      const j = await r.json();
      if ("error" in j) throw j.error;
      return j.result;
    },
  };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
  window.__floEmit = (event, payload) => {
    for (const id of listeners[event] || []) {
      const cb = callbacks.get(id); if (cb) cb({ event, id: 0, payload });
    }
  };
})();
"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/__ipc":
            try:
                res = {"result": handle(req["cmd"], req.get("args") or {})}
            except Exception as e:  # surface as a Tauri-style error
                res = {"error": f"{type(e).__name__}: {e}"}
            STATE["log"].append(req["cmd"])
            return self._send(200, json.dumps(res).encode(), "application/json")
        if self.path == "/__control":
            op = req.get("op")
            if op == "unknown":
                out = sorted(STATE["unknown"])
            elif op == "reset":
                STATE["sessions"].clear(); STATE["settings_overrides"].clear(); out = True
            elif op == "set_session":
                STATE["sessions"][req["root"]] = req["session"]; out = True
            elif op == "settings":
                STATE["settings_overrides"].update(req.get("overrides", {})); out = True
            else:
                out = None
            return self._send(200, json.dumps({"result": out}).encode(), "application/json")
        self._send(404, b"{}", "application/json")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/__asset":
            p = Path(urllib.parse.parse_qs(u.query)["path"][0])
            if p.exists():
                return self._send(200, p.read_bytes(), mimetypes.guess_type(str(p))[0] or "application/octet-stream")
            return self._send(404, b"", "text/plain")
        rel = u.path.lstrip("/") or "index.html"
        f = (DIST / rel).resolve()
        if not str(f).startswith(str(DIST)) or not f.exists():
            f = DIST / "index.html"
        body = f.read_bytes()
        if f.name == "index.html":
            body = body.replace(b"<head>", b"<head><script>" + SHIM.encode() + b"</script>", 1)
        self._send(200, body, mimetypes.guess_type(str(f))[0] or "text/html")


if __name__ == "__main__":
    ensure_sandbox()
    if not (DIST / "index.html").exists():
        sys.exit(f"{DIST} not built: set WRITER_REPO to a writer-computer checkout and build apps/desktop")
    print(f"oracle backend on :{PORT}, sandbox={SANDBOX}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
