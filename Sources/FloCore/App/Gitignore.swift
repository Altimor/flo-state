import Foundation

/// Result of matching a path against gitignore rules (`ignore::Match`).
public enum IgnoreMatch: Equatable {
    case none
    case ignore
    case whitelist
}

/// One `.gitignore`-style file: its rules are relative to `root` (the
/// directory containing the file). Port of `ignore::gitignore::Gitignore`
/// (the parts the app uses), including globset's `**` and `{a,b}` semantics.
public struct Gitignore {
    struct Rule {
        let original: String
        let actual: String
        let isWhitelist: Bool
        let isOnlyDir: Bool
        let regex: NSRegularExpression
    }

    public let root: String
    let rules: [Rule]

    public var isEmpty: Bool { rules.isEmpty }

    /// Load `path` (a gitignore file); rules are rooted at its parent directory.
    /// Unreadable files yield an empty matcher.
    public init(fileURL: URL) {
        let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        self.init(root: fileURL.deletingLastPathComponent().path, content: content)
    }

    public init(root: String, content: String) {
        var r = root
        if r.hasPrefix("./") { r.removeFirst(2) }
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        self.root = r
        var rules: [Rule] = []
        for line in ConfigFile.rustLines(content) {
            if let rule = Gitignore.parseLine(line) { rules.append(rule) }
        }
        self.rules = rules
    }

    static func parseLine(_ rawLine: String) -> Rule? {
        if rawLine.hasPrefix("#") { return nil }
        var line = Substring(rawLine)
        if !line.hasSuffix("\\ ") {
            while let last = line.unicodeScalars.last, last.properties.isWhitespace { line = line.dropLast() }
        }
        if line.isEmpty { return nil }
        let original = String(line)
        var isWhitelist = false
        var isAbsolute = false
        if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line = line.dropFirst()
            isAbsolute = line.first == "/"
        } else {
            if line.hasPrefix("!") { isWhitelist = true; line = line.dropFirst() }
            if line.hasPrefix("/") { line = line.dropFirst(); isAbsolute = true }
        }
        var isOnlyDir = false
        if line.hasSuffix("/") {
            isOnlyDir = true
            line = line.dropLast()
            if line.hasSuffix("\\") { line = line.dropLast() }
        }
        var actual = String(line)
        if !isAbsolute && !line.contains("/") {
            if !(actual.hasPrefix("**/") || actual == "**") { actual = "**/" + actual }
        }
        if actual.hasSuffix("/**") { actual += "/*" }
        guard let pattern = GlobTranslator.regex(for: actual),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        return Rule(original: original, actual: actual, isWhitelist: isWhitelist, isOnlyDir: isOnlyDir, regex: regex)
    }

    /// `Gitignore::strip`.
    func strip(_ path: String) -> String {
        var p = path
        if p.hasPrefix("./") { p.removeFirst(2) }
        let isFileName = !p.contains("/")
        if root != "." && !isFileName {
            if let rest = Gitignore.stripPathPrefix(root, p) {
                p = rest
                if p.hasPrefix("/") { p.removeFirst() }
            }
        }
        return p
    }

    /// Component-wise prefix strip (Rust `Path::strip_prefix`).
    static func stripPathPrefix(_ prefix: String, _ path: String) -> String? {
        if prefix == path { return "" }
        if prefix == "/" { return path.hasPrefix("/") ? String(path.dropFirst()) : nil }
        let pre = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        if path.hasPrefix(pre + "/") { return String(path.dropFirst(pre.count + 1)) }
        return nil
    }

    func matchedStripped(_ path: String, isDir: Bool) -> IgnoreMatch {
        if rules.isEmpty { return .none }
        let range = NSRange(path.startIndex..., in: path)
        for rule in rules.reversed() {
            guard rule.regex.firstMatch(in: path, options: [.anchored], range: range) != nil else { continue }
            if !rule.isOnlyDir || isDir { return rule.isWhitelist ? .whitelist : .ignore }
        }
        return .none
    }

    /// `Gitignore::matched`: the path itself only.
    public func matched(_ path: String, isDir: Bool) -> IgnoreMatch {
        if rules.isEmpty { return .none }
        return matchedStripped(strip(path), isDir: isDir)
    }

    /// `Gitignore::matched_path_or_any_parents`.
    public func matchedPathOrAnyParents(_ path: String, isDir: Bool) -> IgnoreMatch {
        if rules.isEmpty { return .none }
        var p = strip(path)
        let m = matchedStripped(p, isDir: isDir)
        if m != .none { return m }
        while let slash = p.lastIndex(of: "/") {
            p = String(p[..<slash])
            let m = matchedStripped(p, isDir: true)
            if m != .none { return m }
        }
        if !p.isEmpty {
            // Rust's `Path::parent` of a single component is "" which never matches.
            return .none
        }
        return .none
    }
}

/// globset → regex translation (literal_separator + backslash_escape).
enum GlobTranslator {
    enum Token {
        case literal(Character)
        case any
        case zeroOrMore
        case recursivePrefix
        case recursiveSuffix
        case recursiveZeroOrMore
        case cls(negated: Bool, items: [(Character, Character)])
        case alternates([[Token]])
    }

    static func regex(for glob: String) -> String? {
        var parser = Parser(chars: Array(glob))
        guard let tokens = parser.parse() else { return nil }
        return "^" + render(tokens) + "$"
    }

    static func render(_ tokens: [Token]) -> String {
        var out = ""
        // globset: a glob that is only `**` matches everything.
        if tokens.count == 1, case .recursivePrefix = tokens[0] { return ".*" }
        for t in tokens {
            switch t {
            case let .literal(c): out += NSRegularExpression.escapedPattern(for: String(c))
            case .any: out += "[^/]"
            case .zeroOrMore: out += "[^/]*"
            case .recursivePrefix: out += "(?:/?|.*/)"
            case .recursiveSuffix: out += "/.*"
            case .recursiveZeroOrMore: out += "(?:/|/.*/)"
            case let .cls(negated, items):
                out += "["
                if negated { out += "^" }
                for (a, b) in items {
                    out += classEscape(a)
                    if a != b { out += "-" + classEscape(b) }
                }
                out += "]"
            case let .alternates(alts):
                out += "(?:" + alts.map { render($0) }.joined(separator: "|") + ")"
            }
        }
        return out
    }

    static func classEscape(_ c: Character) -> String {
        if "\\[]^-&~".contains(c) { return "\\" + String(c) }
        return NSRegularExpression.escapedPattern(for: String(c))
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        var stack: [[Token]] = [[]]
        var alts: [[[Token]]] = []

        init(chars: [Character]) { self.chars = chars }

        mutating func push(_ t: Token) { stack[stack.count - 1].append(t) }

        mutating func parse() -> [Token]? {
            var prev: Character? = nil
            while i < chars.count {
                let c = chars[i]
                i += 1
                switch c {
                case "?": push(.any)
                case "*": parseStar(prev: prev)
                case "[": guard parseClass() else { return nil }
                case "{":
                    alts.append([])
                    stack.append([])
                case "}":
                    guard !alts.isEmpty else { push(.literal("}")); break }
                    var group = alts.removeLast()
                    group.append(stack.removeLast())
                    push(.alternates(group))
                case "," where !alts.isEmpty:
                    alts[alts.count - 1].append(stack.removeLast())
                    stack.append([])
                case "\\":
                    guard i < chars.count else { return nil }
                    push(.literal(chars[i]))
                    i += 1
                default:
                    push(.literal(c))
                }
                prev = c
            }
            guard alts.isEmpty else { return nil }
            return stack[0]
        }

        mutating func parseStar(prev: Character?) {
            if i >= chars.count || chars[i] != "*" { push(.zeroOrMore); return }
            i += 1 // second '*'
            let current = stack[stack.count - 1]
            if current.isEmpty && stack.count == 1 {
                if i < chars.count && chars[i] != "/" {
                    push(.zeroOrMore); push(.zeroOrMore)
                } else {
                    push(.recursivePrefix)
                    if i < chars.count { i += 1 } // consume '/'
                }
                return
            }
            if prev != "/" {
                if stack.count <= 1 || (prev != "," && prev != "{") {
                    push(.zeroOrMore); push(.zeroOrMore); return
                }
            }
            let isSuffix: Bool
            if i >= chars.count {
                isSuffix = true
            } else if (chars[i] == "," || chars[i] == "}") && stack.count >= 2 {
                isSuffix = true
            } else if chars[i] == "/" {
                i += 1
                isSuffix = false
            } else {
                push(.zeroOrMore); push(.zeroOrMore); return
            }
            let last = stack[stack.count - 1].popLast()
            switch last {
            case .recursivePrefix?: push(.recursivePrefix)
            case .recursiveSuffix?: push(.recursiveSuffix)
            default:
                // The popped token is the '/' separator literal (or nothing inside a brace).
                if case let .literal(ch)? = last, ch != "/" { push(.literal(ch)) }
                push(isSuffix ? .recursiveSuffix : .recursiveZeroOrMore)
            }
        }

        mutating func parseClass() -> Bool {
            var negated = false
            var items: [(Character, Character)] = []
            if i < chars.count && (chars[i] == "!" || chars[i] == "^") { negated = true; i += 1 }
            var first = true
            var inRange = false
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "]" && !first {
                    if inRange { items.append(("-", "-")) }
                    push(.cls(negated: negated, items: items))
                    return true
                }
                first = false
                if c == "-" && !items.isEmpty && !inRange {
                    inRange = true
                    continue
                }
                if inRange, let last = items.popLast() {
                    items.append((last.0, c))
                    inRange = false
                } else {
                    items.append((c, c))
                }
            }
            return false // unclosed class
        }
    }
}

/// Per-workspace gitignore matcher (port of `ignore.rs::WorkspaceIgnore`):
/// every `.gitignore` below the root, each scoped to its own directory,
/// deepest scope first, plus the hard-coded `node_modules` / `.git` safety net.
public struct WorkspaceIgnore {
    struct Scoped {
        let scope: String
        let matcher: Gitignore
    }

    let gitignores: [Scoped]

    /// Safety net only (used while the full matcher loads).
    public static func bootstrap() -> WorkspaceIgnore { WorkspaceIgnore(gitignores: []) }

    init(gitignores: [Scoped]) { self.gitignores = gitignores }

    /// Walks directories below `root` (dot-directories included, `.git` and
    /// `node_modules` skipped, directories hidden by already-collected rules
    /// not descended) and probes each for a `.gitignore`.
    public static func load(root: URL) -> WorkspaceIgnore {
        let fm = FileManager.default
        var collected: [Scoped] = []
        var rootPath = root.path
        while rootPath.count > 1 && rootPath.hasSuffix("/") { rootPath.removeLast() }
        var queue: [String] = [rootPath]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            let candidate = (dir as NSString).appendingPathComponent(".gitignore")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                collected.append(Scoped(scope: dir, matcher: Gitignore(fileURL: URL(fileURLWithPath: candidate))))
                collected.sort { depth($0.scope) > depth($1.scope) }
            }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let partial = WorkspaceIgnore(gitignores: collected)
            for name in names.sorted() where name != ".git" && name != "node_modules" {
                let child = (dir as NSString).appendingPathComponent(name)
                var childIsDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
                if isSymlink(child) { continue }
                if partial.matchesRules(child, isDir: true) { continue }
                queue.append(child)
            }
        }
        collected.sort { depth($0.scope) > depth($1.scope) }
        return WorkspaceIgnore(gitignores: collected)
    }

    static func depth(_ path: String) -> Int { path.split(separator: "/").count + (path.hasPrefix("/") ? 1 : 0) }

    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func matchesRules(_ path: String, isDir: Bool) -> Bool {
        for scoped in gitignores {
            guard Gitignore.stripPathPrefix(scoped.scope, path) != nil else { continue }
            switch scoped.matcher.matchedPathOrAnyParents(path, isDir: isDir) {
            case .ignore: return true
            case .whitelist: return false
            case .none: continue
            }
        }
        return false
    }

    /// Hidden from sidebar, watcher and search?
    public func isIgnored(_ path: String, isDir: Bool) -> Bool {
        if WorkspaceIgnore.hasSafetyComponent(path) { return true }
        return matchesRules(path, isDir: isDir)
    }

    public func isIgnored(_ url: URL, isDir: Bool) -> Bool { isIgnored(url.path, isDir: isDir) }

    static func hasSafetyComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "node_modules" || $0 == ".git" }
    }

    /// `is_gitignore_path`.
    public static func isGitignorePath(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == ".gitignore"
    }
}
