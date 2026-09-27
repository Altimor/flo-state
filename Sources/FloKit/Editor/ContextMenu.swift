import AppKit
import FloCore

// Editor body context menu (editor-context-menu.ts buildEditorBodyMenuItemsSpec
// + use-prosemark-editor.ts editorBodyContextMenuExtension).

public struct EditorMenuSpec: Equatable {
    public enum Entry: Equatable {
        case item(id: String, title: String, key: String?)
        case separator
        case submenu(title: String, items: [Entry])
    }
    public var entries: [Entry]
}

extension EditorFeatures {
    /// Formatting command registry used by the menu's `onRunCommand`.
    static func command(_ id: String) -> Command? {
        switch id {
        case "format.bold": return Formatting.toggleBold
        case "format.italic": return Formatting.toggleItalic
        case "format.link": return Formatting.insertLink
        case "format.code": return Formatting.toggleInlineCode
        case "format.strikethrough": return Formatting.toggleStrikethrough
        case "format.bulletList": return Formatting.toggleBulletList
        case "format.numberedList": return Formatting.toggleNumberedList
        case "format.blockquote": return Formatting.toggleBlockquote
        case "format.taskList": return Formatting.toggleTaskList
        case "format.heading1": return Formatting.setHeading(1)
        case "format.heading2": return Formatting.setHeading(2)
        case "format.heading3": return Formatting.setHeading(3)
        case "format.heading4": return Formatting.setHeading(4)
        case "format.heading5": return Formatting.setHeading(5)
        case "format.heading6": return Formatting.setHeading(6)
        case "format.paragraph": return Formatting.setParagraph
        case "clearInlineFormatting": return Formatting.clearInlineFormatting
        case "toggleFencedCodeBlock": return Formatting.toggleFencedCodeBlock
        case "insertTable": return Formatting.insertTable
        case "insertHorizontalRule": return Formatting.insertHorizontalRule
        case "insertToday": return Formatting.insertToday
        case "insertNow": return Formatting.insertNow
        default: return nil
        }
    }

    /// The menu layout (ids, titles, macOS accelerator labels).
    public static func menuSpec(hasLink: Bool) -> EditorMenuSpec {
        typealias E = EditorMenuSpec.Entry
        var e: [E] = [
            .item(id: "cut", title: "Cut", key: nil),
            .item(id: "copy", title: "Copy", key: nil),
            .item(id: "paste", title: "Paste", key: nil),
            .item(id: "paste-plain", title: "Paste as plain text", key: nil),
            .separator,
            .submenu(title: "Format", items: [
                .item(id: "format.bold", title: "Bold", key: "Mod-b"),
                .item(id: "format.italic", title: "Italic", key: "Mod-i"),
                .item(id: "format.strikethrough", title: "Strikethrough", key: "Mod-Shift-x"),
                .item(id: "format.code", title: "Inline code", key: "Mod-e"),
                .separator,
                .item(id: "format.link", title: "Insert link\u{2026}", key: "Mod-k"),
                .separator,
                .item(id: "clearInlineFormatting", title: "Clear formatting", key: nil),
            ]),
            .submenu(title: "Paragraph", items: [
                .item(id: "format.heading1", title: "Heading 1", key: "Mod-Alt-1"),
                .item(id: "format.heading2", title: "Heading 2", key: "Mod-Alt-2"),
                .item(id: "format.heading3", title: "Heading 3", key: "Mod-Alt-3"),
                .item(id: "format.heading4", title: "Heading 4", key: "Mod-Alt-4"),
                .item(id: "format.heading5", title: "Heading 5", key: "Mod-Alt-5"),
                .item(id: "format.heading6", title: "Heading 6", key: "Mod-Alt-6"),
                .item(id: "format.paragraph", title: "Paragraph", key: "Mod-Alt-0"),
                .separator,
                .item(id: "format.bulletList", title: "Bullet list", key: "Mod-Shift-8"),
                .item(id: "format.numberedList", title: "Numbered list", key: "Mod-Shift-7"),
                .item(id: "format.taskList", title: "Task list", key: "Mod-Shift-Enter"),
                .separator,
                .item(id: "format.blockquote", title: "Blockquote", key: "Mod-Shift-."),
                .item(id: "toggleFencedCodeBlock", title: "Code block", key: nil),
            ]),
            .submenu(title: "Insert", items: [
                .item(id: "format.link", title: "Link\u{2026}", key: "Mod-k"),
                .item(id: "insertTable", title: "Table", key: nil),
                .item(id: "insertHorizontalRule", title: "Horizontal rule", key: nil),
                .separator,
                .item(id: "insertToday", title: "Current date", key: nil),
                .item(id: "insertNow", title: "Current time", key: nil),
            ]),
            .separator,
            .item(id: "select-all", title: "Select all", key: nil),
        ]
        if hasLink {
            e += [.separator, .item(id: "open-link", title: "Open link", key: nil), .item(id: "copy-link", title: "Copy link", key: nil)]
        }
        return EditorMenuSpec(entries: e)
    }

    /// `getLinkHref(view, pos) ?? getRawUrl(view, pos)`: the destination of a
    /// markdown Link, or a bare/autolink URL, touching `pos` (last match wins).
    public func menuLinkHref(at pos: Int) -> String? {
        let st = editor.state
        var href: String? = nil
        st.tree.iterate(from: pos, to: pos, enter: { n, _ in
            guard n.name == "Link" else { return true }
            for c in n.children where c.name == "URL" {
                href = LinkPaths.normalizeMarkdownDestination(st.doc.slice(c.from, c.to))
                break
            }
            return false
        })
        if href != nil { return href }
        var raw: String? = nil
        st.tree.iterate(from: pos, to: pos, enter: { n, _ in
            guard n.name == "URL" else { return true }
            if n.parent?.name == "Link" { return false }
            raw = LinkPaths.normalizeMarkdownDestination(st.doc.slice(n.from, n.to))
            return false
        })
        return raw
    }

    /// Build the native menu for a right-click at `event`.
    func contextMenu(for event: NSEvent) -> NSMenu? {
        let tv = editor.textView
        let i = tv.characterIndexForInsertion(at: tv.convert(event.locationInWindow, from: nil))
        let href = i == NSNotFound ? nil : menuLinkHref(at: i)
        return buildMenu(linkHref: href)
    }

    public func buildMenu(linkHref: String?) -> NSMenu {
        let spec = Self.menuSpec(hasLink: linkHref != nil)
        func make(_ entries: [EditorMenuSpec.Entry], title: String) -> NSMenu {
            let m = NSMenu(title: title)
            m.autoenablesItems = false
            for e in entries {
                switch e {
                case .separator: m.addItem(.separator())
                case .submenu(let t, let items):
                    let it = NSMenuItem(title: L(t), action: nil, keyEquivalent: "")
                    it.submenu = make(items, title: L(t))
                    m.addItem(it)
                case .item(let id, let t, let key):
                    let it = NSMenuItem(title: L(t), action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
                    if let k = key { let (ke, mods) = Self.keyEquivalent(k); it.keyEquivalent = ke; it.keyEquivalentModifierMask = mods }
                    it.representedObject = id
                    it.target = menuTarget
                    m.addItem(it)
                }
            }
            return m
        }
        menuTarget.features = self
        menuTarget.linkHref = linkHref
        let m = make(spec.entries, title: "Editor")
        m.allowsContextMenuPlugIns = false // exactly the app's items (no Services)
        return m
    }

    /// "Mod-Shift-8" → ("8", [.command, .shift]) for the accelerator label.
    static func keyEquivalent(_ chord: String) -> (String, NSEvent.ModifierFlags) {
        var parts = chord.components(separatedBy: "-")
        let key = parts.removeLast()
        var mods: NSEvent.ModifierFlags = []
        for p in parts {
            switch p {
            case "Mod": mods.insert(.command)
            case "Shift": mods.insert(.shift)
            case "Alt": mods.insert(.option)
            case "Ctrl": mods.insert(.control)
            default: break
            }
        }
        let ke = key == "Enter" ? "\r" : key.lowercased()
        return (ke, mods)
    }

    /// Run a menu action by id (also used by tests).
    public func performMenuAction(_ id: String, linkHref: String? = nil, pasteboard: NSPasteboard = .general) {
        let c = editor
        switch id {
        case "cut":
            let r = c.state.selection.main
            if r.empty { return }
            pasteboard.clearContents()
            pasteboard.setString(c.state.sliceDoc(r.from, r.to), forType: .string)
            c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: r.from, to: r.to)])); return true }
        case "copy":
            let r = c.state.selection.main
            if r.empty { return }
            pasteboard.clearContents()
            pasteboard.setString(c.state.sliceDoc(r.from, r.to), forType: .string)
        case "paste", "paste-plain":
            // readText(): plain text only, no image/HTML handling
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
            c.run { t in t.dispatch(t.state.replaceSelection(text)); return true }
        case "select-all":
            c.run { t in t.dispatch(TransactionSpec(selection: .single(0, t.state.doc.length))); return true }
        case "open-link":
            if let h = linkHref { c.onLinkClick?(.href(h)) }
        case "copy-link":
            if let h = linkHref { pasteboard.clearContents(); pasteboard.setString(h, forType: .string) }
        default:
            c.textView.window?.makeFirstResponder(c.textView)
            if let cmd = Self.command(id) { c.run(cmd) }
        }
    }

}

final class MenuTarget: NSObject {
    weak var features: EditorFeatures?
    var linkHref: String?
    @objc func fire(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        features?.performMenuAction(id, linkHref: linkHref)
    }
}
