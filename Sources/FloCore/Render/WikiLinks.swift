import Foundation

/// Display/parse helpers from src/lib/wiki-links.ts used by the renderer.
enum WikiLinks {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitAlias(_ raw: String) -> (target: String, alias: String?) {
        let u = Array(raw.utf16)
        guard let sep = u.firstIndex(of: 124) else { return (raw, nil) }
        let escaped = sep > 0 && u[sep - 1] == 92
        let targetEnd = escaped ? sep - 1 : sep
        let target = String(utf16CodeUnits: Array(u[0..<targetEnd]), count: targetEnd)
        let alias = String(utf16CodeUnits: Array(u[(sep + 1)...]), count: u.count - sep - 1)
        return (target, unescape(alias))
    }

    static func normalizeTarget(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while t.hasPrefix("/") { t.removeFirst() }
        let lower = t.lowercased()
        if lower.hasSuffix(".md") { t = String(t.dropLast(3)) } else if lower.hasSuffix(".markdown") { t = String(t.dropLast(9)) }
        return t
    }

    static func displayText(_ raw: String) -> String {
        let (target, alias) = splitAlias(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let normalizedTarget = unescape(target)
        var path = normalizedTarget, fragment: String? = nil
        if let h = normalizedTarget.firstIndex(of: "#") {
            path = String(normalizedTarget[..<h]); fragment = String(normalizedTarget[normalizedTarget.index(after: h)...])
        }
        let np = normalizeTarget(path)
        let fallback = !np.isEmpty ? np : (fragment.map { "#" + $0 } ?? normalizedTarget)
        if let a = alias, !a.isEmpty { return a }
        return fallback
    }

    static func imageEmbedTarget(_ raw: String) -> String? {
        let (target, _) = splitAlias(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var path = unescape(target).replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") { path.removeFirst() }
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex, path.index(after: dot) != path.endIndex else { return nil }
        let ext = path[path.index(after: dot)...].lowercased()
        return imageExtensions.contains(ext) ? path : nil
    }
}
