"""Keystroke replay in the real app via CDP Input events (goes through CM keymaps
and input handlers exactly like a user typing)."""

MOD = {"Alt": 1, "Ctrl": 2, "Mod": 4, "Meta": 4, "Shift": 8}

NAMED = {
    "Enter": ("Enter", "Enter", 13, "\r"),
    "Backspace": ("Backspace", "Backspace", 8, None),
    "Delete": ("Delete", "Delete", 46, None),
    "Tab": ("Tab", "Tab", 9, None),
    "Escape": ("Escape", "Escape", 27, None),
    "Left": ("ArrowLeft", "ArrowLeft", 37, None),
    "Right": ("ArrowRight", "ArrowRight", 39, None),
    "Up": ("ArrowUp", "ArrowUp", 38, None),
    "Down": ("ArrowDown", "ArrowDown", 40, None),
    "Home": ("Home", "Home", 36, None),
    "End": ("End", "End", 35, None),
    "Space": (" ", "Space", 32, " "),
}

SHIFTED = {"!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5",
           "^": "Digit6", "&": "Digit7", "*": "Digit8", "(": "Digit9", ")": "Digit0",
           "_": "Minus", "+": "Equal", "~": "Backquote", "{": "BracketLeft", "}": "BracketRight",
           "|": "Backslash", ":": "Semicolon", '"': "Quote", "<": "Comma", ">": "Period", "?": "Slash"}
PLAIN = {"-": ("Minus", 189), "=": ("Equal", 187), "`": ("Backquote", 192), "[": ("BracketLeft", 219),
         "]": ("BracketRight", 221), "\\": ("Backslash", 220), ";": ("Semicolon", 186),
         "'": ("Quote", 222), ",": ("Comma", 188), ".": ("Period", 190), "/": ("Slash", 191)}
SHIFT_KEYCODE = {"Digit1": 49, "Digit2": 50, "Digit3": 51, "Digit4": 52, "Digit5": 53, "Digit6": 54,
                 "Digit7": 55, "Digit8": 56, "Digit9": 57, "Digit0": 48, "Minus": 189, "Equal": 187,
                 "Backquote": 192, "BracketLeft": 219, "BracketRight": 221, "Backslash": 220,
                 "Semicolon": 186, "Quote": 222, "Comma": 188, "Period": 190, "Slash": 191}


def char_event(ch):
    if ch.isalpha() and ch.isascii():
        code = "Key" + ch.upper()
        return ch, code, ord(ch.upper()), (8 if ch.isupper() else 0)
    if ch.isdigit():
        return ch, "Digit" + ch, ord(ch), 0
    if ch == " ":
        return " ", "Space", 32, 0
    if ch in SHIFTED:
        c = SHIFTED[ch]
        return ch, c, SHIFT_KEYCODE[c], 8
    if ch in PLAIN:
        c, kc = PLAIN[ch]
        return ch, c, kc, 0
    return ch, "", 0, 0


def press(o, spec):
    """spec: 'Enter', 'Shift-Tab', 'Mod-b', 'Mod-Shift-x', 'Mod-Alt-1' ..."""
    parts = spec.split("-")
    # handle 'Mod--' style (minus key)
    if spec.endswith("--"):
        parts = spec[:-2].split("-") + ["-"]
    mods = 0
    for p in parts[:-1]:
        mods |= MOD[p]
    k = parts[-1]
    if k in NAMED:
        key, code, kc, text = NAMED[k]
    else:
        key, code, kc, extra = char_event(k)
        mods |= extra
        text = key
    with_text = text if (mods & (MOD["Mod"] | MOD["Ctrl"] | MOD["Alt"])) == 0 else None
    params = dict(type="keyDown" if with_text else "rawKeyDown", key=key, code=code,
                  modifiers=mods, windowsVirtualKeyCode=kc, nativeVirtualKeyCode=kc)
    if with_text:
        params["text"] = with_text
        params["unmodifiedText"] = with_text
    if mods & MOD["Mod"] and len(key) == 1:
        params["commands"] = []
    o.cmd("Input.dispatchKeyEvent", **params)
    o.cmd("Input.dispatchKeyEvent", type="keyUp", key=key, code=code, modifiers=mods,
          windowsVirtualKeyCode=kc, nativeVirtualKeyCode=kc)


def type_text(o, s):
    for ch in s:
        if ch == "\n":
            press(o, "Enter")
        else:
            key, code, kc, mods = char_event(ch)
            o.cmd("Input.dispatchKeyEvent", type="keyDown", key=key, code=code, text=ch,
                  unmodifiedText=ch, modifiers=mods, windowsVirtualKeyCode=kc, nativeVirtualKeyCode=kc)
            o.cmd("Input.dispatchKeyEvent", type="keyUp", key=key, code=code, modifiers=mods,
                  windowsVirtualKeyCode=kc, nativeVirtualKeyCode=kc)


CURSOR, ANCHOR, HEAD = "‸", "«", "»"


def split_marked(s):
    """'- fo‸o' -> ('- foo', anchor, head). «...» marks anchor..head selection."""
    doc, a, h = "", None, None
    for ch in s:
        if ch == CURSOR:
            a = h = len(doc.encode("utf-16-le")) // 2
        elif ch == ANCHOR:
            a = len(doc.encode("utf-16-le")) // 2
        elif ch == HEAD:
            h = len(doc.encode("utf-16-le")) // 2
        else:
            doc += ch
    if a is None:
        a = h = 0
    if h is None:
        h = a
    return doc, a, h


# ---- WebKit oracle: real NSEvents (mac virtual key codes) ----------------------
MAC_NAMED = {"Enter": (36, "\r"), "Backspace": (51, "\x7f"), "Delete": (117, ""), "Tab": (48, "\t"),
             "Escape": (53, "\x1b"), "Left": (123, ""), "Right": (124, ""), "Up": (126, ""),
             "Down": (125, ""), "Home": (115, ""), "End": (119, ""), "Space": (49, " ")}
MAC_CODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
             "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
             "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
             "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49}
MAC_SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
               "_": "-", "+": "=", "~": "`", "{": "[", "}": "]", "|": "\\", ":": ";", '"': "'", "<": ",", ">": ".", "?": "/"}


def is_wk(o):
    return hasattr(o, "_send") and getattr(o, "port", 1) is None


def wk_press(o, spec):
    parts = spec.split("-")
    if spec == "-":
        parts = ["-"]
    elif spec.endswith("--"):
        parts = spec[:-2].split("-") + ["-"]
    mods = {"Mod": "cmd", "Meta": "cmd", "Shift": "shift", "Alt": "alt", "Ctrl": "ctrl"}
    ms = [mods[p] for p in parts[:-1]]
    k = parts[-1]
    if k in MAC_NAMED:
        code, ch = MAC_NAMED[k]
        ign = ch
        if k == "Tab" and "shift" in ms:
            ch = "\x19"
    else:
        base = MAC_SHIFTED.get(k, k.lower())
        if k in MAC_SHIFTED or (k.isalpha() and k.isupper()):
            if "shift" not in ms: ms.append("shift")
        code = MAC_CODES.get(base, 0)
        ch, ign = k, base
        if "shift" in ms and k.isalpha():
            ch = ign = k.upper()
    o._send({"key": {"chars": ch, "ign": ign, "keyCode": code, "mods": ms}})


def wk_type(o, s):
    for ch in s:
        wk_press(o, "Enter" if ch == "\n" else ch)


_press, _type = press, type_text


def press(o, spec):  # noqa: F811
    return wk_press(o, spec) if is_wk(o) else _press(o, spec)


def type_text(o, s):  # noqa: F811
    return wk_type(o, s) if is_wk(o) else _type(o, s)
