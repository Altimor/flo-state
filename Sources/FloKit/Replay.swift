import AppKit
import FloCore

/// Replays recorded web-app keystrokes as real NSEvents through an offscreen
/// EditorController (keyDown → interpretKeyEvents → insertText, menu key
/// equivalents), so the whole AppKit input path is exercised.
@MainActor
public final class KeyReplayer {
    public let window: NSWindow
    public let controller: EditorController

    public init(width: CGFloat = 1400, height: CGFloat = 900) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        controller = EditorController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = content
        controller.scrollView.frame = content.bounds
        content.addSubview(controller.scrollView)
        controller.layoutColumn()
        window.makeFirstResponder(controller.textView)
    }

    public func load(_ doc: String, selection: EditorSelection) {
        controller.load(doc, selection: selection)
        controller.layoutColumn()
        // async widgets (KaTeX, mermaid, HTML blocks) take their final size before measuring
        controller.waitForAsyncWidgets()
        let tlm = controller.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        window.makeFirstResponder(controller.textView)
    }

    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "~": "`", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]
    static let named: [String: (UInt16, String)] = [
        "Enter": (36, "\r"), "Backspace": (51, "\u{7F}"), "Delete": (117, "\u{F728}"), "Tab": (48, "\t"),
        "Escape": (53, "\u{1B}"), "Left": (123, "\u{F702}"), "Right": (124, "\u{F703}"), "Up": (126, "\u{F700}"),
        "Down": (125, "\u{F701}"), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"), "Space": (49, " "),
    ]

    /// "Mod-Shift-x", "Enter", "t:typed text" (fixture format).
    public func press(_ spec: String) {
        if spec.hasPrefix("t:") {
            for ch in spec.dropFirst(2) { press(Self.charSpec(ch)) }
            return
        }
        if spec == "\n" { press("Enter"); return }
        var parts = spec.count == 1 ? [spec] : spec.components(separatedBy: "-")
        if spec.count > 1 && spec.hasSuffix("--") { parts = Array(spec.dropLast(2).components(separatedBy: "-")) + ["-"] }
        let key = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for p in parts {
            switch p {
            case "Mod", "Meta", "Cmd": flags.insert(.command)
            case "Alt": flags.insert(.option)
            case "Ctrl": flags.insert(.control)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        var code: UInt16 = 0
        var chars = key, ignoring = key
        if let (c, s) = Self.named[key] {
            code = c; chars = s; ignoring = s
            if key == "Tab" && flags.contains(.shift) { chars = "\u{19}"; ignoring = "\u{19}" }
            if flags.contains(.option) || flags.contains(.command) || flags.contains(.control) { chars = s }
        } else if let k = key.first {
            if let base = Self.shifted[k] { code = Self.keyCodes[base] ?? 0; flags.insert(.shift) }
            else { code = Self.keyCodes[Character(k.lowercased())] ?? 0 }
            if k.isUppercase { flags.insert(.shift) }
            // Shift+letter chord: characters come uppercase; shifted digit gives the symbol
            var produced = String(k)
            if flags.contains(.shift), let base = Self.shifted.first(where: { $0.value == k })?.key { produced = String(base) }
            if flags.contains(.shift) && k.isLetter { produced = produced.uppercased() }
            ignoring = produced
            chars = flags.contains(.command) || flags.contains(.control) ? produced : produced
        }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                                        isARepeat: false, keyCode: code) else { return }
        if flags.contains(.command), window.performKeyEquivalent(with: ev) { return }
        controller.textView.keyDown(with: ev)
    }

    static func charSpec(_ ch: Character) -> String {
        if ch == " " { return "Space" }
        return String(ch)
    }

    public var doc: String { controller.state.doc.string }
    public var selection: EditorSelection { controller.state.selection }
    /// The text view's own content (must always equal `doc`).
    public var viewText: String { controller.textView.string }
}

extension KeyReplayer {
    /// Layout primitives at a caret: [lbF, lbB, vDown, vUp] as (head, assoc).
    public func probe(_ pos: Int) -> [(Int, Int)] {
        let st = controller.state
        let r = SelectionRange.cursor(pos)
        let l = controller.layout
        return [l.moveToLineBoundary(st, r, forward: true, includeWrap: true),
                l.moveToLineBoundary(st, r, forward: false, includeWrap: true),
                l.moveVertically(st, r, forward: true),
                l.moveVertically(st, r, forward: false)].map { ($0.head, $0.assoc) }
    }
}

public extension NSAttributedString.Key {
    static let floWidgetKey = NSAttributedString.Key.floWidget
    static let floGlyphShiftKey = NSAttributedString.Key.floGlyphShift
}

public enum PlanCacheStats { public static var mismatches: Int { PlanCache.mismatches } }

/// Attribute equality for the fuzz check (widgets compare by content).
public func attrEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x as WidgetBox, y as WidgetBox): return x.widget.kind == y.widget.kind && x.widget.to - x.widget.from == y.widget.to - y.widget.from && x.width == y.width && x.size == y.size
    case let (x as NSObject, y as NSObject): return x.isEqual(y)
    default: return false
    }
}
