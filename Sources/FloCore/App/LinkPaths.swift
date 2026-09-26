import Foundation

/// Where a markdown link points (`paths.ts::LinkTarget`).
public enum LinkTarget: Equatable {
    case internalFile(path: String, anchor: String?)
    case sameDocAnchor(String)
    case externalURL(String)
    case externalPath(String)
}

/// Port of `src/lib/paths.ts`. String semantics follow JS (UTF-16 indices).
public enum LinkPaths {
    static let windowsAbsolute = #"^[A-Za-z]:[\\/]"#
    static let explicitScheme = #"^[A-Za-z][A-Za-z\d+.-]*:"#
    static let markdownEscapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t")

    public static func getFileExtension(_ path: String) -> String {
        let ns = path as NSString
        let lastDot = ns.range(of: ".", options: .backwards).location
        let lastSlash = max(rangeLoc(ns.range(of: "/", options: .backwards)), rangeLoc(ns.range(of: "\\", options: .backwards)))
        guard lastDot != NSNotFound, lastDot > lastSlash + 1 else { return "" }
        return ns.substring(from: lastDot + 1)
    }

    private static func rangeLoc(_ r: NSRange) -> Int { r.location == NSNotFound ? -1 : r.location }

    public static func getFileName(_ path: String) -> String {
        let ns = path as NSString
        let lastSlash = max(rangeLoc(ns.range(of: "/", options: .backwards)), rangeLoc(ns.range(of: "\\", options: .backwards)))
        return ns.substring(from: lastSlash + 1)
    }

    public static func getFileStem(_ path: String) -> String {
        let name = getFileName(path) as NSString
        let lastDot = rangeLoc(name.range(of: ".", options: .backwards))
        if lastDot <= 0 { return name as String }
        return name.substring(to: lastDot)
    }

    public static func getRelativePath(_ fullPath: String, root: String) -> String {
        let normalized = fullPath.replacingOccurrences(of: "\\", with: "/")
        var normalizedRoot = root.replacingOccurrences(of: "\\", with: "/")
        if normalizedRoot.hasSuffix("/") { normalizedRoot.removeLast() }
        if normalized.hasPrefix(normalizedRoot + "/") { return String(normalized.dropFirst(normalizedRoot.count + 1)) }
        return normalized
    }

    public static func getParentDir(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/") as NSString
        let lastSlash = rangeLoc(normalized.range(of: "/", options: .backwards))
        if lastSlash <= 0 { return "/" }
        return normalized.substring(to: lastSlash)
    }

    /// `decodeURIComponent`, falling back to the input on malformed escapes.
    public static func decodeLinkPath(_ path: String) -> String {
        guard path.contains("%") else { return path }
        return path.removingPercentEncoding ?? path
    }

    static func unescapeMarkdownDestination(_ path: String) -> String {
        var result = ""
        let chars = Array(path)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, markdownEscapable.contains(chars[i + 1]) {
                result.append(chars[i + 1])
                i += 2
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    public static func normalizeMarkdownDestination(_ destination: String) -> String {
        var normalized = AppRegex.trim(destination)
        if normalized.hasPrefix("<") && normalized.hasSuffix(">") && normalized.count >= 2 {
            normalized = AppRegex.trim(String(normalized.dropFirst().dropLast()))
        } else if normalized == "<>" {
            normalized = ""
        }
        return unescapeMarkdownDestination(normalized)
    }

    public static func normalizeLocalMarkdownDestination(_ destination: String) -> String {
        decodeLinkPath(normalizeMarkdownDestination(destination))
    }

    /// Wraps destinations containing whitespace or `<>` in angle brackets.
    public static func formatMarkdownDestination(_ destination: String) -> String {
        guard AppRegex.test(destination, "[\(AppRegex.ws.dropFirst().dropLast())<>]") else { return destination }
        let escaped = destination.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        return "<\(escaped)>"
    }

    public static func normalizePath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let isWindowsAbsolute = AppRegex.test(normalized, windowsAbsolute)
        let hasLeadingSlash = normalized.hasPrefix("/")
        var stack: [String] = []
        for part in normalized.components(separatedBy: "/") {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    if isWindowsAbsolute || hasLeadingSlash || !AppRegex.test(last, windowsAbsolute) {
                        stack.removeLast()
                        continue
                    }
                }
                if !isWindowsAbsolute && !hasLeadingSlash { stack.append(part) }
                continue
            }
            stack.append(part)
        }
        if isWindowsAbsolute {
            let drive = stack.first ?? "undefined" // JS: `${undefined}` when `..` popped the drive
            let rest = stack.dropFirst()
            return rest.isEmpty ? "\(drive)/" : "\(drive)/\(rest.joined(separator: "/"))"
        }
        if hasLeadingSlash { return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/") }
        return stack.joined(separator: "/")
    }

    static func resolvePath(baseDir: String, target: String) -> String {
        if AppRegex.test(target, windowsAbsolute) || target.hasPrefix("/") { return normalizePath(target) }
        var base = baseDir
        if base.hasSuffix("/") { base.removeLast() }
        return normalizePath("\(base)/\(target)")
    }

    static func isPathInsideRoot(_ path: String, root: String) -> Bool {
        let p = normalizePath(path)
        var r = normalizePath(root)
        if r.hasSuffix("/") { r.removeLast() }
        return p == r || p.hasPrefix(r + "/")
    }

    static func splitLinkHref(_ href: String) -> String {
        let ns = href as NSString
        let hash = rangeLoc(ns.range(of: "#"))
        let query = rangeLoc(ns.range(of: "?"))
        let split = hash == -1 ? query : (query == -1 ? hash : min(hash, query))
        return split == -1 ? href : ns.substring(to: split)
    }

    static func extractAnchor(_ href: String) -> String? {
        let ns = href as NSString
        let hash = rangeLoc(ns.range(of: "#"))
        if hash == -1 { return nil }
        let anchor = ns.substring(from: hash + 1)
        return anchor.isEmpty ? nil : decodeLinkPath(anchor)
    }

    /// `resolveLinkTarget`. Probing order for extensionless targets, per base
    /// (the resolved path, then — for `/abs` targets — the workspace-root
    /// mapping): `.md`, `.markdown`, `/index.md`, `/index.markdown`, `/README.md`.
    public static func resolveLinkTarget(
        _ href: String,
        currentFilePath: String,
        workspaceRoot: String? = nil,
        fileExists: ((String) -> Bool)? = nil
    ) -> LinkTarget? {
        let trimmed = normalizeMarkdownDestination(href)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("#") {
            return extractAnchor(trimmed).map { .sameDocAnchor($0) }
        }
        if AppRegex.test(trimmed, explicitScheme) && !AppRegex.test(trimmed, windowsAbsolute) {
            return .externalURL(trimmed)
        }
        let target = splitLinkHref(trimmed)
        if target.isEmpty { return nil }
        let anchor = extractAnchor(trimmed)
        let decodedTarget = decodeLinkPath(target)
        let resolved = resolvePath(baseDir: getParentDir(currentFilePath), target: decodedTarget)
        let ext = getFileExtension(resolved).lowercased()
        let isMarkdown = ext == "md" || ext == "markdown"
        if isMarkdown && (workspaceRoot.map { $0.isEmpty } ?? true || isPathInsideRoot(resolved, root: workspaceRoot!)) {
            return .internalFile(path: resolved, anchor: anchor)
        }
        if ext.isEmpty, let fileExists = fileExists {
            var bases = [AppRegex.replace(resolved, "/+$", "")]
            let isPosixAbsolute = decodedTarget.hasPrefix("/") && !AppRegex.test(decodedTarget, windowsAbsolute)
            if isPosixAbsolute, let root = workspaceRoot, !root.isEmpty {
                var r = root
                if r.hasSuffix("/") { r.removeLast() }
                let rootRelative = AppRegex.replace(normalizePath(r + decodedTarget), "/+$", "")
                if !bases.contains(rootRelative) { bases.append(rootRelative) }
            }
            for base in bases {
                for candidate in ["\(base).md", "\(base).markdown", "\(base)/index.md", "\(base)/index.markdown", "\(base)/README.md"] {
                    if let root = workspaceRoot, !root.isEmpty, !isPathInsideRoot(candidate, root: root) { continue }
                    if fileExists(candidate) { return .internalFile(path: candidate, anchor: anchor) }
                }
            }
        }
        return .externalPath(resolved)
    }

    /// `.csv` opens without markdown parsing.
    public static func isPlainTextPath(_ path: String) -> Bool {
        getFileExtension(path).lowercased() == "csv"
    }

    public static func resolveImagePath(_ imageSrc: String, markdownDir: String) -> String {
        let src = normalizeMarkdownDestination(imageSrc)
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return src }
        let local = decodeLinkPath(src)
        if local.hasPrefix("/") { return local }
        var dir = markdownDir
        if dir.hasSuffix("/") { dir.removeLast() }
        return "\(dir)/\(local)"
    }
}

// MARK: - Wiki links (src/lib/wiki-links.ts)

public struct ParsedWikiLink: Equatable {
    public var raw: String
    public var target: String
    public var path: String
    public var fragment: String?
    public var alias: String?
    public var displayText: String
}

public enum WikiLinkTarget: Equatable {
    case internalFile(String)
    case unresolved
}

public enum WikiLinkResolver {
    static func unescapeWikiText(_ text: String) -> String {
        AppRegex.trim(text.replacingOccurrences(of: "\\|", with: "|"))
    }

    static func splitAlias(_ raw: String) -> (target: String, alias: String?) {
        let ns = raw as NSString
        let sep = ns.range(of: "|").location
        if sep == NSNotFound { return (raw, nil) }
        let escaped = sep > 0 && ns.substring(with: NSRange(location: sep - 1, length: 1)) == "\\"
        let targetEnd = escaped ? sep - 1 : sep
        return (ns.substring(to: targetEnd), unescapeWikiText(ns.substring(from: sep + 1)))
    }

    static func splitFragment(_ target: String) -> (path: String, fragment: String?) {
        let ns = target as NSString
        let hash = ns.range(of: "#").location
        if hash == NSNotFound { return (target, nil) }
        return (ns.substring(to: hash), ns.substring(from: hash + 1))
    }

    public static func parse(_ raw: String) -> ParsedWikiLink {
        let (target, alias) = splitAlias(AppRegex.trim(raw))
        let normalizedTarget = unescapeWikiText(target)
        let (path, fragment) = splitFragment(normalizedTarget)
        let normalizedPath = normalizeTarget(path)
        let fallback = !normalizedPath.isEmpty ? normalizedPath : ((fragment?.isEmpty == false) ? "#\(fragment!)" : normalizedTarget)
        let aliasValue = (alias?.isEmpty == false) ? alias : nil
        return ParsedWikiLink(raw: raw, target: normalizedTarget, path: normalizedPath, fragment: fragment,
                              alias: aliasValue, displayText: aliasValue ?? fallback)
    }

    /// Trim, `\` → `/`, strip leading `/`, strip `.md` / `.markdown` (case-insensitive).
    public static func normalizeTarget(_ raw: String) -> String {
        var target = AppRegex.replace(AppRegex.trim(raw).replacingOccurrences(of: "\\", with: "/"), "^/+", "")
        let lower = target.lowercased()
        if lower.hasSuffix(".md") { target = String(target.dropLast(3)) }
        else if lower.hasSuffix(".markdown") { target = String(target.dropLast(9)) }
        return target
    }

    /// `resolveWikiLink`: paths with `/` resolve workspace-relative (`.md` then
    /// `.markdown`); bare names resolve by unique case-insensitive stem among
    /// fuzzy-search results (limit 50).
    public static func resolve(
        _ raw: String,
        workspaceRoot: String,
        fuzzySearch: (String, Int) -> [SearchResult],
        fileExists: (String) -> Bool,
        currentFilePath: String? = nil
    ) -> WikiLinkTarget {
        let link = parse(raw)
        let target = link.path
        if target.isEmpty, link.fragment?.isEmpty == false, let current = currentFilePath, !current.isEmpty {
            return .internalFile(current)
        }
        if target.isEmpty { return .unresolved }
        if target.contains("/") {
            var root = workspaceRoot
            if root.hasSuffix("/") { root.removeLast() }
            let base = LinkPaths.normalizePath("\(root)/\(target)")
            for candidate in ["\(base).md", "\(base).markdown"] where fileExists(candidate) {
                return .internalFile(candidate)
            }
            return .unresolved
        }
        let lower = target.lowercased()
        let exact = fuzzySearch(target, 50).filter { LinkPaths.getFileStem($0.filename).lowercased() == lower }
        return exact.count == 1 ? .internalFile(exact[0].path) : .unresolved
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]

    /// `parseWikiImageEmbedTarget`: normalized image path, or nil for non-images.
    public static func parseImageEmbedTarget(_ raw: String) -> String? {
        let (target, _) = splitAlias(AppRegex.trim(raw))
        let path = AppRegex.replace(unescapeWikiText(target).replacingOccurrences(of: "\\", with: "/"), "^/+", "")
        let ns = path as NSString
        let dot = ns.range(of: ".", options: .backwards).location
        guard dot != NSNotFound, dot > 0, dot != ns.length - 1 else { return nil }
        return imageExtensions.contains(ns.substring(from: dot + 1).lowercased()) ? path : nil
    }

    /// `resolveWikiImage`.
    public static func resolveImage(
        _ target: String,
        workspaceRoot: String?,
        currentFilePath: String?,
        fileExists: (String) -> Bool,
        findFileByName: (String, String) -> String?
    ) -> String? {
        let noteDir = (currentFilePath?.isEmpty == false) ? LinkPaths.getParentDir(currentFilePath!) : nil
        let root = (workspaceRoot?.isEmpty == false) ? AppRegex.replace(workspaceRoot!, "/$", "") : nil
        var candidates: [String] = []
        func push(_ base: String?) {
            guard let base = base, !base.isEmpty else { return }
            let p = LinkPaths.normalizePath("\(base)/\(target)")
            if !candidates.contains(p) { candidates.append(p) }
        }
        if target.contains("/") { push(root); push(noteDir) } else { push(noteDir); push(root) }
        for c in candidates where fileExists(c) { return c }
        if let root = root, !target.contains("/") { return findFileByName(root, target) }
        return nil
    }

    /// `canonicalWikiTarget`: bare stem when unique, else the relative path without `.md`.
    public static func canonicalTarget(_ file: SearchResult, allFiles: [SearchResult]) -> String {
        let stem = LinkPaths.getFileStem(file.filename)
        let lower = stem.lowercased()
        let dup = allFiles.contains { $0.path != file.path && LinkPaths.getFileStem($0.filename).lowercased() == lower }
        if !dup { return stem }
        let rel = file.relativePath
        let l = rel.lowercased()
        if l.hasSuffix(".md") { return String(rel.dropLast(3)) }
        if l.hasSuffix(".markdown") { return String(rel.dropLast(9)) }
        return rel
    }
}
