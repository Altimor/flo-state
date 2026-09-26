"""Headless-Chrome driver for the Flo State oracle (real frontend + mock backend)."""
import base64
import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path

import websocket

from paths import tmpdir

CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
HERE = Path(__file__).resolve().parent
SERVER_PORT = int(os.environ.get("FLO_ORACLE_PORT", "5288"))  # oracle/server.py


class Oracle:
    def __init__(self, port=9344, server_port=SERVER_PORT, width=1400, height=900, headless=True):
        self.port, self.server_port = port, server_port
        self.url = f"http://127.0.0.1:{server_port}/"
        prof = str(tmpdir(f"chrome-{port}"))
        subprocess.run(["pkill", "-9", "-f", f"flo-oracle/chrome-{port}"], capture_output=True)
        time.sleep(0.3)
        args = [CHROME, f"--remote-debugging-port={port}", "--remote-allow-origins=*",
                f"--user-data-dir={prof}", "--no-first-run", "--no-default-browser-check",
                f"--window-size={width},{height}", "--force-device-scale-factor=2",
                "--hide-scrollbars", "about:blank"]
        if headless:
            args.insert(1, "--headless=new")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ws_url = None
        for _ in range(100):
            try:
                tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json").read())
                pages = [t for t in tabs if t["type"] == "page"]
                if pages:
                    ws_url = pages[0]["webSocketDebuggerUrl"]
                    break
            except Exception:
                pass
            time.sleep(0.1)
        if not ws_url:
            raise RuntimeError("chrome devtools endpoint never came up")
        self.ws = websocket.create_connection(ws_url, max_size=None, timeout=30)
        self._id = 0
        self.console = []
        self.cmd("Page.enable")
        self.cmd("Runtime.enable")
        self.cmd("Emulation.setDeviceMetricsOverride", width=width, height=height,
                 deviceScaleFactor=2, mobile=False)

    def cmd(self, method, **params):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
            if msg.get("method") == "Runtime.consoleAPICalled":
                self.console.append(" ".join(str(a.get("value", a.get("description", "")))
                                             for a in msg["params"]["args"]))
            elif msg.get("method") == "Runtime.exceptionThrown":
                d = msg["params"]["exceptionDetails"]
                self.console.append("EXCEPTION " + (d.get("exception", {}).get("description") or d.get("text", "")))

    def js(self, expr, await_promise=True):
        r = self.cmd("Runtime.evaluate", expression=expr, returnByValue=True,
                     awaitPromise=await_promise)
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            raise RuntimeError("JS error: " + (d.get("exception", {}).get("description") or d.get("text")))
        return r.get("result", {}).get("value")

    def control(self, **req):
        data = json.dumps(req).encode()
        r = urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{self.server_port}/__control", data=data, method="POST"))
        return json.loads(r.read())["result"]

    def load(self, timeout=20):
        self.cmd("Page.navigate", url=self.url)
        return self.wait("!!document.querySelector('.cm-content')", timeout)

    def wait(self, cond, timeout=10, interval=0.05):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if self.js(cond):
                    return True
            except RuntimeError:
                pass
            time.sleep(interval)
        return False

    def screenshot(self, path):
        r = self.cmd("Page.captureScreenshot", format="png")
        Path(path).write_bytes(base64.b64decode(r["data"]))
        return path

    def key(self, key, code=None, text=None, modifiers=0, key_code=0):
        """Real keyboard input through CDP (goes through CodeMirror's keymaps)."""
        base = dict(key=key, code=code or key, modifiers=modifiers,
                    windowsVirtualKeyCode=key_code, nativeVirtualKeyCode=key_code)
        self.cmd("Input.dispatchKeyEvent", type="keyDown" if text is None else "keyDown",
                 text=text or "", **base)
        self.cmd("Input.dispatchKeyEvent", type="keyUp", **base)

    def type_text(self, s):
        self.cmd("Input.insertText", text=s)

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass
        self.proc.kill()
        subprocess.run(["pkill", "-9", "-f", f"flo-oracle/chrome-{self.port}"], capture_output=True)
        time.sleep(0.5)


class WKOracle(Oracle):
    """Same interface, driven through an offscreen WKWebView (oracle/wk) — the
    engine the real Tauri app runs on macOS."""
    def __init__(self, server_port=SERVER_PORT, width=1400, height=900, **_):
        self.server_port = server_port
        self.url = f"http://127.0.0.1:{server_port}/"
        self.width, self.height = width, height
        self.console = []
        self.proc = subprocess.Popen([str(HERE / "wk" / "wkoracle")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.port = None

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n"); self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("wkoracle died")
        r = json.loads(line)
        if "error" in r:
            raise RuntimeError("JS error: " + r["error"])
        return r["result"]

    def js(self, expr, await_promise=True):
        # indirect eval: global scope, accepts statements as well as expressions
        return self._send({"js": "(0, eval)(" + json.dumps(expr) + ")"})

    def load(self, timeout=20):
        self._send({"load": self.url, "width": self.width, "height": self.height})
        return self.wait("!!document.querySelector('.cm-content')", timeout)

    def screenshot(self, path):
        self._send({"screenshot": str(path)})
        return path

    def cmd(self, method, **params):
        raise RuntimeError(f"CDP {method} not available in the WebKit oracle")

    def close(self):
        try:
            self.proc.stdin.write(json.dumps({"quit": 1}) + "\n"); self.proc.stdin.flush()
        except Exception:
            pass
        try:
            self.proc.wait(3)
        except Exception:
            self.proc.kill()


ENGINE = os.environ.get("ORACLE_ENGINE", "webkit")

from paths import SANDBOX, ensure_sandbox  # noqa: E402
SCRATCH = SANDBOX / "__oracle.md"


def boot(width=1400, height=900, port=9344, file=None, settings=None):
    """Start Chrome on the real app with a single scratch tab, inject page.js."""
    ensure_sandbox()
    target = Path(file) if file else SCRATCH
    if not file:
        SCRATCH.write_text("")
    o = (WKOracle if ENGINE == "webkit" else Oracle)(port=port, width=width, height=height)
    o.control(op="reset")
    if settings:
        o.control(op="settings", overrides=settings)
    o.control(op="set_session", root=str(SANDBOX), session={
        "tabs": [{"location": {"kind": "file", "path": str(target)}, "back": [], "forward": []}],
        "active_index": 0})
    if not o.load(30):
        raise RuntimeError("editor did not mount; console: " + "\n".join(o.console[-10:]))
    o.js((HERE / "page.js").read_text())
    o.js("__flo.settle()")
    return o
