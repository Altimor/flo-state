#!/usr/bin/env python3
"""App-shell parity: web oracle (real frontend in headless Chrome) vs the native
`FloStateNative --shell-snapshot`. For every scenario both sides dump frames of
the key chrome elements (sidebar, rows, tabs, footer, rail, palette, settings)
and screenshots; this script diffs the frames.

usage: shell_parity.py [scenario-substring] [--web-only] [--native-only] [--port N]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from cdp import Oracle, SANDBOX  # noqa: E402
from paths import TMP, ensure_sandbox, native_binary  # noqa: E402

OUT = Path(os.environ.get("SHELL_OUT", TMP / "shell"))
USER_CONFIG = Path.home() / "Library/Application Support/com.writer-computer/config"

S = str(SANDBOX)
NOTES, GROCERIES, JOURNAL, PROJECT = f"{S}/Notes.md", f"{S}/Groceries.md", f"{S}/Journal.md", f"{S}/Project Alpha.md"


def ftab(p):
    return {"location": {"kind": "file", "path": p}, "back": [], "forward": []}


BASE = {"appearance.sidebar-visible": True, "appearance.theme": "light", "appearance.sidebar-show-recents": False,
        "editor.jump-to-bottom-after-minutes": 0}  # the web's cold-start jump is racy
THREE = [ftab(NOTES), ftab(GROCERIES), ftab(JOURNAL)]

SCENARIOS = [
    dict(name="w1400", size=(1400, 900), tabs=THREE, active=0),
    dict(name="recents", size=(1400, 900), tabs=THREE, active=0, settings={"appearance.sidebar-show-recents": True}, loose_labels=True),
    dict(name="w1200", size=(1200, 800), tabs=THREE, active=1),
    dict(name="w800-autohide", size=(800, 700), tabs=THREE, active=0),
    dict(name="dark1200", size=(1200, 800), tabs=THREE, active=0, settings={"appearance.theme": "dark"}),
    dict(name="collapsed1200", size=(1200, 800), tabs=THREE, active=2, settings={"appearance.sidebar-visible": False}),
    dict(name="stats-outline", size=(1400, 900), tabs=[ftab(JOURNAL)], active=0,
         settings={"statusbar.show-words": True, "statusbar.show-characters": True,
                   "statusbar.show-paragraphs": True, "editor.show-outline": True,
                   "editor.jump-to-bottom-after-minutes": 0}),  # the web's cold-start jump is racy
    dict(name="expanded", size=(1400, 900), tabs=[ftab(PROJECT)], active=0, expand=[f"{S}/Archive"]),
    dict(name="frontmatter", size=(1400, 900), tabs=[ftab(f"{S}/__shell_fm.md")], active=0,
         create={"__shell_fm.md": "---\ntitle: Shell FM\ntags: a\nstatus: draft\n---\n# Heading\n\nBody text.\n"}),
    dict(name="pinned", size=(1000, 800), tabs=THREE, active=1, pinned=[NOTES, PROJECT],
         settings={"appearance.sidebar-width": 400}),
    dict(name="launcher", size=(1200, 800), tabs=[ftab(NOTES)], active=0, action="newtab"),
    dict(name="palette", size=(1400, 900), tabs=THREE, active=0, action="palette"),
    dict(name="palette-query", size=(1400, 900), tabs=THREE, active=0, action="palette:jou",
         ignore=["palette.heading"]),  # the mock backend never finishes indexing
    dict(name="palette-create", size=(1400, 900), tabs=THREE, active=0, action="create:My note"),
]


def settings_for(sc):
    s = dict(BASE)
    s.update(sc.get("settings", {}))
    return s


# ---------------------------------------------------------------- web side

def web_dump(sc, port):
    w, h = sc["size"]
    o = Oracle(port=port, width=w, height=h)
    try:
        o.control(op="reset")
        o.control(op="settings", overrides=settings_for(sc))
        o.control(op="set_session", root=S, session={"tabs": sc["tabs"], "active_index": sc["active"]})
        if sc.get("pinned"):
            key = f"writer:pref:workspace:{S}:sidebar-pinned-files"
            o.cmd("Page.addScriptToEvaluateOnNewDocument",
                  source=f"localStorage.setItem({json.dumps(key)}, {json.dumps(json.dumps(sc['pinned']))})")
        o.cmd("Page.navigate", url=o.url)
        if not o.wait("!!document.querySelector('[data-tab-id]')", 30):
            raise RuntimeError("web shell did not mount: " + "\n".join(o.console[-5:]))
        time.sleep(1.2)
        for d in sc.get("expand", []):
            o.js(f"document.querySelector('[data-tree-path=\"{d}\"]').click()")
            time.sleep(0.5)
        act = sc.get("action")
        if act == "newtab":
            o.js("document.querySelector('button[aria-label=\"New tab\"]').click()")
        elif act and act.startswith("palette"):
            o.key("o", code="KeyO", modifiers=4, key_code=79)
            time.sleep(0.3)
            q = act.split(":", 1)[1] if ":" in act else ""
            if q:
                o.type_text(q)
                time.sleep(0.6)
        elif act and act.startswith("create:"):
            o.js("window.__floEmit('menu:new-note', null)")
            time.sleep(0.3)
            o.type_text(act.split(":", 1)[1])
        time.sleep(0.8)
        o.js("document.activeElement && document.activeElement.blur && (document.activeElement.closest('.cm-editor') ? 0 : 0)")
        dump = o.js((HERE / "shell_dump.js").read_text())
        o.screenshot(str(OUT / f"web-{sc['name']}.png"))
        return dump
    finally:
        o.close()


# ---------------------------------------------------------------- native side

def config_text(overrides):
    lines = USER_CONFIG.read_text().splitlines() if USER_CONFIG.exists() else []
    keys = set(overrides)
    lines = [l for l in lines if l.split("=", 1)[0].strip() not in keys]
    for k, v in overrides.items():
        if isinstance(v, bool):
            v = "true" if v else "false"
        lines.append(f"{k} = {v}")
    return "\n".join(lines) + "\n"


def native_dump(sc):
    w, h = sc["size"]
    data = Path(tempfile.mkdtemp(prefix="flo-shell-"))
    try:
        (data / "config").write_text(config_text(settings_for(sc)))
        (data / "sessions.json").write_text(json.dumps({S: {"tabs": sc["tabs"], "active_index": sc["active"]}}))
        (data / "recent_workspaces.json").write_text(json.dumps([S]))
        if sc.get("pinned"):
            (data / "sidebar_pinned.json").write_text(json.dumps({S: sc["pinned"]}))
        args = [str(native_binary()), "--shell-snapshot", S, "--data-dir", str(data), "--width", str(w), "--height", str(h),
                "--out", str(OUT / f"native-{sc['name']}.png"), "--dump", str(data / "dump.json")]
        for d in sc.get("expand", []):
            args += ["--expand", d]
        if sc.get("action"):
            args += ["--action", sc["action"]]
        r = subprocess.run(args, capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            raise RuntimeError(f"native snapshot failed ({r.returncode}): {r.stderr[-2000:]}")
        return json.loads((data / "dump.json").read_text())
    finally:
        shutil.rmtree(data, ignore_errors=True)


# ---------------------------------------------------------------- diff

class Diff:
    def __init__(self, tol=1.0, ignore=()):
        self.tol, self.ok, self.bad, self.lines = tol, 0, 0, []
        self.ignore = set(ignore)

    def rect(self, path, a, b):
        if a is None and b is None:
            self.ok += 1
            return
        if a is None or b is None:
            self.bad += 1
            self.lines.append(f"  {path}: web={a} native={b}")
            return
        d = max(abs(x - y) for x, y in zip(a, b))
        if d <= self.tol:
            self.ok += 1
        else:
            self.bad += 1
            self.lines.append(f"  {path}: web={a} native={b} (Δ{d:.2f})")

    def val(self, path, a, b):
        if path in self.ignore:
            return
        if a == b:
            self.ok += 1
        else:
            self.bad += 1
            self.lines.append(f"  {path}: web={a!r} native={b!r}")

    def list(self, path, a, b, fn):
        a, b = a or [], b or []
        if len(a) != len(b):
            self.bad += 1
            self.lines.append(f"  {path}: count web={len(a)} native={len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            fn(f"{path}[{i}]", x, y)


def compare(web, nat, loose=False, ignore=()):
    d = Diff(ignore=ignore)
    d.val("sidebarVisible", web.get("sidebarVisible"), nat.get("sidebarVisible"))
    d.rect("sidebarToggle", web.get("sidebarToggle"), nat.get("sidebarToggle"))
    if web.get("sidebarVisible"):
        d.rect("sidebarPanel", web.get("sidebarPanel"), nat.get("sidebarPanel"))
        ws, ns = web.get("workspaceSwitcher") or {}, nat.get("workspaceSwitcher") or {}
        d.rect("workspaceSwitcher", ws.get("rect"), ns.get("rect"))
        d.val("workspaceSwitcher.label", ws.get("label"), ns.get("label"))

        def sec(p, x, y):
            d.val(p + ".label", x["label"], y["label"])
            d.rect(p, x["rect"], y["rect"])
        d.list("sections", web.get("sections"), nat.get("sections"), sec)

        def row(p, x, y):
            if not loose and "__" not in (x.get("path") or "") + (y.get("path") or ""):  # lead's scratch files change underneath
                d.val(p + ".label", x["label"], y["label"])
            d.rect(p, x["rect"], y["rect"])
            d.val(p + ".active", x["active"], y["active"])
            if abs(x["labelX"] - y["labelX"]) > 1:
                d.bad += 1
                d.lines.append(f"  {p}.labelX: web={x['labelX']} native={y['labelX']}")
            else:
                d.ok += 1
        d.list("rows", web.get("rows"), nat.get("rows"), row)

    def tab(p, x, y):
        d.val(p + ".title", x["title"], y["title"])
        d.rect(p, x["rect"], y["rect"])
        d.val(p + ".active", x["active"], y["active"])
    d.list("tabs", web.get("tabs"), nat.get("tabs"), tab)
    d.rect("newTabButton", web.get("newTabButton"), nat.get("newTabButton"))
    wf, nf = web.get("footer"), nat.get("footer")
    if wf or nf:
        d.rect("footer", (wf or {}).get("rect"), (nf or {}).get("rect"))
        d.val("footer.text", (wf or {}).get("text"), (nf or {}).get("text"))

    web_jumped = bool(web.get("editorProbe")) and web["editorProbe"][1] < 0

    def tick(p, x, y):
        if web_jumped:  # racy cold-start jump in the web: only the stack geometry is comparable
            d.val(p + ".y", x["rect"][1], y["rect"][1])
        else:
            d.rect(p, x["rect"], y["rect"])
            d.val(p + ".active", x["active"], y["active"])
        d.val(p + ".title", x["title"], y["title"])
    d.list("railTicks", web.get("railTicks"), nat.get("railTicks"), tick)
    wp, np_ = web.get("palette"), nat.get("palette")
    if wp or np_:
        wp, np_ = wp or {}, np_ or {}
        d.rect("palette", wp.get("rect"), np_.get("rect"))
        d.rect("palette.input", wp.get("input"), np_.get("input"))
        d.val("palette.placeholder", wp.get("placeholder"), np_.get("placeholder"))
        d.val("palette.heading", wp.get("heading"), np_.get("heading"))
        d.val("palette.empty", wp.get("empty"), np_.get("empty"))

        def item(p, x, y):
            d.val(p + ".text", x["text"], y["text"])
            d.rect(p, x["rect"], y["rect"])
            d.val(p + ".selected", x["selected"], y["selected"])
        d.list("palette.items", wp.get("items"), np_.get("items"), item)
    wl, nl = web.get("launcher"), nat.get("launcher")
    if wl or nl:
        def lb(p, x, y):
            d.val(p + ".text", x["text"], y["text"])
            d.rect(p, x["rect"], y["rect"])
        d.list("launcher", wl, nl, lb)
    ws_, ns_ = web.get("settings"), nat.get("settings")
    if ws_ or ns_:
        ws_, ns_ = ws_ or {}, ns_ or {}
        d.rect("settings.title", ws_.get("title"), ns_.get("title"))

        def ss(p, x, y):
            d.val(p + ".label", x["label"], y["label"])
            d.rect(p, x["rect"], y["rect"])
            d.rect(p + ".card", x["card"], y["card"])
        d.list("settings.sections", ws_.get("sections"), ns_.get("sections"), ss)

        def sr(p, x, y):
            d.val(p + ".label", x["label"], y["label"])
            d.rect(p, x["rect"], y["rect"])
        d.list("settings.rows", ws_.get("rows"), ns_.get("rows"), sr)
    wfm, nfm = web.get("frontmatter"), nat.get("frontmatter")
    if wfm or nfm:
        wfm, nfm = wfm or {}, nfm or {}

        def fr(p, x, y):
            d.rect(p, x["rect"], y["rect"])
            d.val(p + ".kv", (x["key"], x["value"]), (y["key"], y["value"]))
        d.list("frontmatter.rows", wfm.get("rows"), nfm.get("rows"), fr)
        d.rect("frontmatter.add", wfm.get("add"), nfm.get("add"))
    d.val("title", web.get("title"), nat.get("title"))
    if web.get("editorProbe") or nat.get("editorProbe"):
        # editor text origin (FloKit's domain; reported, 1px tolerance)
        wp_, np2 = web.get("editorProbe"), nat.get("editorProbe")
        if wp_ and wp_[1] < 0:
            d.lines.append(f"  (editorProbe skipped: the web pane scrolled on open ({wp_[1]}), a known web race)")
            wp_ = np2 = None
        d.rect("editorProbe", wp_ + [0, 0] if wp_ else None, np2 + [0, 0] if np2 else None)
    return d


def pixel_diff(name, web):
    """Mean |Δ| (0-255) over chrome regions: sidebar column and tab bar."""
    try:
        from PIL import Image, ImageChops, ImageStat
    except ImportError:
        return None
    a = Image.open(OUT / f"web-{name}.png").convert("RGB")
    b = Image.open(OUT / f"native-{name}.png").convert("RGB")
    if a.size != b.size:
        return {"size": (a.size, b.size)}
    k = a.size[0] / web["window"][2]
    regions = {"tabbar": (web.get("sidebarPanel", [0, 0, 0])[2] + 16 if web.get("sidebarVisible") else 0, 0, web["window"][2], 56)}
    if web.get("sidebarVisible"):
        p = web["sidebarPanel"]
        regions["sidebar"] = (0, 0, p[0] + p[2] + 4, web["window"][3])
    out = {}
    for rn, (x0, y0, x1, y1) in regions.items():
        box = tuple(int(v * k) for v in (x0, y0, x1, y1))
        diff = ImageChops.difference(a.crop(box), b.crop(box))
        out[rn] = round(sum(ImageStat.Stat(diff).mean) / 3, 2)
    return out


def main():
    args = sys.argv[1:]
    port = 9350
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    flt = next((a for a in args if not a.startswith("--") and not a.isdigit()), None)
    ensure_sandbox()
    OUT.mkdir(parents=True, exist_ok=True)
    tot_ok = tot_bad = 0
    for sc in SCENARIOS:
        if flt and flt not in sc["name"]:
            continue
        created = []
        for rel, content in sc.get("create", {}).items():
            (SANDBOX / rel).write_text(content)
            created.append(SANDBOX / rel)
        wpath = OUT / f"web-{sc['name']}.json"
        if "--native-only" in args and wpath.exists():
            web = json.loads(wpath.read_text())
        else:
            web = web_dump(sc, port)
            wpath.write_text(json.dumps(web, indent=1, ensure_ascii=False))
        if "--web-only" in args:
            print(f"{sc['name']}: web dumped")
            continue
        nat = native_dump(sc)
        (OUT / f"native-{sc['name']}.json").write_text(json.dumps(nat, indent=1, ensure_ascii=False))
        for c in created:
            c.unlink(missing_ok=True)
        d = compare(web, nat, loose=sc.get("loose_labels", False), ignore=sc.get("ignore", ()))
        tot_ok += d.ok
        tot_bad += d.bad
        print(f"{sc['name']}: {d.ok}/{d.ok + d.bad}  pixels(mean|Δ|): {pixel_diff(sc['name'], web)}")
        for l in d.lines[:40]:
            print(l)
    if tot_ok + tot_bad:
        print(f"SHELL PARITY: {tot_ok}/{tot_ok + tot_bad}")


if __name__ == "__main__":
    main()
