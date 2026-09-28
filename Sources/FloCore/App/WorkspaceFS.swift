import Foundation

/// Which files the editor can open (port of `open_target.rs` extension logic).
public struct SupportedExtensions: Equatable {
    /// Rust fallback when `files.associations` has not produced a list.
    public static let fallback = ["md", "markdown", "mdx", "txt", "csv"]

    public let extensions: [String]

    /// `set_supported_extensions`: `*.ext` patterns → `ext` (lowercased);
    /// anything else ignored; an empty result keeps the fallback list.
    public init(patterns: [String]) {
        let exts = patterns.compactMap { p -> String? in
            let t = ConfigFile.rustTrim(p)
            guard t.hasPrefix("*.") else { return nil }
            let e = String(t.dropFirst(2)).lowercased()
            return e.isEmpty ? nil : e
        }
        extensions = exts.isEmpty ? SupportedExtensions.fallback : exts
    }

    public static let `default` = SupportedExtensions(patterns: [])

    /// Schema default (`*.md, *.mdx, *.markdown, *.csv`).
    public static var schemaDefault: SupportedExtensions {
        SupportedExtensions(patterns: SettingsSchema.def("files.associations")?.defaultValue.listValue ?? [])
    }

    /// `is_supported_file`: Rust `Path::extension` semantics (a leading-dot
    /// name like `.md` has no extension), ASCII case-insensitive.
    public func isSupported(_ path: String) -> Bool {
        guard let ext = WorkspaceFS.rustExtension(path) else { return false }
        return extensions.contains { $0.caseInsensitiveCompare(ext) == .orderedSame }
    }
}

/// A sidebar entry (`fs.rs::DirEntry`).
public struct DirEntry: Equatable {
    public var name: String
    public var path: String
    public var isDir: Bool
    /// Wire name kept from the web app: "the editor can open this".
    public var isMarkdown: Bool
    /// Unix seconds.
    public var modifiedAt: UInt64
    public var title: String?
}

public struct FileContent: Equatable {
    public var path: String
    public var content: String
    public var modifiedAt: UInt64
    public init(path: String, content: String, modifiedAt: UInt64 = 0) {
        self.path = path; self.content = content; self.modifiedAt = modifiedAt
    }
}

public struct WriteResult: Equatable {
    public var path: String
    public var modifiedAt: UInt64
}

public struct ImageSaveResult: Equatable {
    public var relativePath: String
    public var absolutePath: String
}

public enum AppError: Error, Equatable, CustomStringConvertible {
    case io(String)
    case notFound(String)
    case alreadyExists(String)
    case noWorkspace

    /// Matches the web app's serialized error strings.
    public var description: String {
        switch self {
        case let .io(m): return L("IO error: %@", m)
        case let .notFound(p): return L("Not found: %@", p)
        case let .alreadyExists(p): return L("Already exists: %@", p)
        case .noWorkspace: return L("No workspace is open")
        }
    }
}

/// Filesystem commands (port of `commands/fs.rs`, `commands/images.rs` and the
/// sidebar's naming helpers). Paths are plain POSIX strings, like the web app.
public enum WorkspaceFS {
    static var fm: FileManager { .default }

    // MARK: Path helpers

    /// Rust `Path::extension`.
    public static func rustExtension(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(name[name.index(after: dot)...])
    }

    /// Rust `Path::file_stem`.
    public static func rustFileStem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    public static func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    public static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    public static func isFile(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && !d.boolValue
    }

    /// `modified_time`: unix seconds, 0 when unavailable.
    public static func modifiedTime(_ path: String) -> UInt64 {
        guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return 0 }
        let t = date.timeIntervalSince1970
        return t > 0 ? UInt64(t) : 0
    }

    // MARK: Titles

    /// `extract_title`: reads the first 4096 bytes; frontmatter `title:` wins,
    /// else a leading `# ` heading. Like the Rust, returns nil when the 4 KB
    /// prefix is not valid UTF-8 (e.g. cut mid-character).
    public static func extractTitle(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return extractTitle(text: text)
    }

    public static func extractTitle(text: String) -> String? {
        let bytes = Array(text.utf8)
        var restStart: Int?
        if bytes.starts(with: Array("---\n".utf8)) { restStart = 4 }
        else if bytes.starts(with: Array("---\r\n".utf8)) { restStart = 5 }
        if let restStart = restStart {
            let rest = Array(bytes[restStart...])
            if let endPos = findBytes(rest, Array("\n---\n".utf8)) ?? findBytes(rest, Array("\n---\r\n".utf8)) {
                let yaml = String(decoding: rest[..<endPos], as: UTF8.self)
                for line in ConfigFile.rustLines(yaml) {
                    let trimmed = ConfigFile.rustTrim(line)
                    guard trimmed.hasPrefix("title:") else { continue }
                    let value = ConfigFile.rustTrim(String(trimmed.dropFirst(6)))
                    var title = value
                    if value.unicodeScalars.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                        title = String(value.unicodeScalars.dropFirst().dropLast())
                    } else if value.unicodeScalars.count >= 2 && value.hasPrefix("'") && value.hasSuffix("'") {
                        title = String(value.unicodeScalars.dropFirst().dropLast())
                    }
                    if !title.isEmpty { return title }
                }
                // Rust slices `rest[end_pos + "\n---\n".len()..]` even when the
                // match was the `\r\n` variant.
                let bodyStart = min(rest.count, endPos + 5)
                return extractLeadingH1(String(decoding: rest[bodyStart...], as: UTF8.self))
            }
        }
        return extractLeadingH1(text)
    }

    static func findBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0] && Array(haystack[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// `extract_leading_h1`: the first non-blank line must be `# …`.
    public static func extractLeadingH1(_ text: String) -> String? {
        for line in ConfigFile.rustLines(text) {
            let trimmed = ConfigFile.rustTrim(line)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# ") {
                let title = ConfigFile.rustTrim(String(trimmed.dropFirst(2)))
                if !title.isEmpty { return title }
            }
            return nil
        }
        return nil
    }

    // MARK: Directory listing

    /// Recursive fallback for "does this folder contain an openable file?"
    /// (`dir_contains_markdown_recursive`).
    public static func dirContainsSupportedFile(_ path: String, ignore: WorkspaceIgnore?, extensions: SupportedExtensions) -> Bool {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return false }
        for name in names {
            let child = (path as NSString).appendingPathComponent(name)
            guard let kind = entryKind(child) else { continue }
            if let ignore = ignore, ignore.isIgnored(child, isDir: kind == .dir) { continue }
            if kind == .file {
                if extensions.isSupported(child) { return true }
            } else if kind == .dir, dirContainsSupportedFile(child, ignore: ignore, extensions: extensions) {
                return true
            }
        }
        return false
    }

    enum EntryKind { case file, dir, other }

    /// Entry type without following symlinks (Rust `DirEntry::file_type`).
    static func entryKind(_ path: String) -> EntryKind? {
        guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return nil }
        switch type {
        case .typeDirectory: return .dir
        case .typeRegular: return .file
        default: return .other
        }
    }

    /// `read_directory_impl`: one level; dot-entries and ignored paths skipped;
    /// folders only when they contain an openable file somewhere below (from
    /// the index's directory set when ready, else a recursive probe); files
    /// carry their title; folders first, each group sorted by lowercased name.
    public static func readDirectory(
        _ path: String,
        ignore: WorkspaceIgnore? = nil,
        extensions: SupportedExtensions = .schemaDefault,
        dirsWithSupportedFiles: Set<String>? = nil
    ) throws -> [DirEntry] {
        guard exists(path) else { throw AppError.notFound(path) }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: path) } catch { throw AppError.io(error.localizedDescription) }
        var dirs: [DirEntry] = []
        var files: [DirEntry] = []
        for name in names {
            if name.hasPrefix(".") { continue }
            let child = (path as NSString).appendingPathComponent(name)
            guard let kind = entryKind(child) else { continue }
            if let ignore = ignore, ignore.isIgnored(child, isDir: kind == .dir) { continue }
            switch kind {
            case .dir:
                let contains = dirsWithSupportedFiles.map { $0.contains(child) }
                    ?? dirContainsSupportedFile(child, ignore: ignore, extensions: extensions)
                if contains {
                    dirs.append(DirEntry(name: name, path: child, isDir: true, isMarkdown: false, modifiedAt: modifiedTime(child), title: nil))
                }
            case .file:
                if extensions.isSupported(child) {
                    files.append(DirEntry(name: name, path: child, isDir: false, isMarkdown: true, modifiedAt: modifiedTime(child), title: extractTitle(child)))
                }
            case .other:
                continue
            }
        }
        let byLowerName: (DirEntry, DirEntry) -> Bool = { rustStringLess($0.name.lowercased(), $1.name.lowercased()) }
        dirs.sort(by: byLowerName)
        files.sort(by: byLowerName)
        return dirs + files
    }

    /// Rust `String` ordering: bytewise UTF-8.
    public static func rustStringLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// `markdown_file_entry`.
    public static func fileEntry(_ path: String, extensions: SupportedExtensions = .schemaDefault) -> DirEntry? {
        guard isFile(path), extensions.isSupported(path) else { return nil }
        return DirEntry(name: (path as NSString).lastPathComponent, path: path, isDir: false, isMarkdown: true,
                        modifiedAt: modifiedTime(path), title: extractTitle(path))
    }

    /// `read_file_entries_impl`: entries for paths inside `root` that are openable files.
    public static func readFileEntries(_ paths: [String], root: String, extensions: SupportedExtensions = .schemaDefault) -> [DirEntry] {
        paths.compactMap { p in
            guard Gitignore.stripPathPrefix(root, p) != nil else { return nil }
            return fileEntry(p, extensions: extensions)
        }
    }

    // MARK: Read / write

    public static func readFile(_ path: String) throws -> FileContent {
        guard exists(path) else { throw AppError.notFound(path) }
        guard let data = fm.contents(atPath: path) else { throw AppError.io("could not read \(path)") }
        guard let content = String(data: data, encoding: .utf8) else {
            throw AppError.io("stream did not contain valid UTF-8")
        }
        return FileContent(path: path, content: content, modifiedAt: modifiedTime(path))
    }

    /// `write_file_impl`: `.~{uuid}` temp file in the same directory, then rename.
    @discardableResult
    public static func writeFile(_ path: String, content: String) throws -> WriteResult {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        guard !dir.path.isEmpty else { throw AppError.io("No parent directory") }
        do {
            try AtomicFile.write(Data(content.utf8), to: url, tempName: ".~\(UUID().uuidString.lowercased())")
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        return WriteResult(path: path, modifiedAt: modifiedTime(path))
    }

    /// Content of a newly created note.
    public static let newFileContent = "# "

    /// `create_file_impl`: fails if the path exists; creates parent folders.
    @discardableResult
    public static func createFile(_ path: String) throws -> FileContent {
        if exists(path) { throw AppError.alreadyExists(path) }
        let url = URL(fileURLWithPath: path)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(newFileContent.utf8).write(to: url)
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        return FileContent(path: path, content: newFileContent, modifiedAt: modifiedTime(path))
    }

    @discardableResult
    public static func createDirectory(_ path: String) throws -> DirEntry {
        if exists(path) { throw AppError.alreadyExists(path) }
        do { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) } catch { throw AppError.io(error.localizedDescription) }
        return DirEntry(name: (path as NSString).lastPathComponent, path: path, isDir: true, isMarkdown: false,
                        modifiedAt: modifiedTime(path), title: nil)
    }

    /// `rename_entry_impl`: fails when the source is missing or the target exists.
    public static func renameEntry(_ oldPath: String, to newPath: String) throws {
        guard exists(oldPath) else { throw AppError.notFound(oldPath) }
        if exists(newPath) { throw AppError.alreadyExists(newPath) }
        do { try fm.moveItem(atPath: oldPath, toPath: newPath) } catch { throw AppError.io(error.localizedDescription) }
    }

    /// `delete_entry_impl`: moves to the Trash. Returns the item's URL in the Trash.
    @discardableResult
    public static func deleteEntry(_ path: String) throws -> URL? {
        guard exists(path) else { throw AppError.notFound(path) }
        var resulting: NSURL?
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        return resulting as URL?
    }

    // MARK: Naming

    /// Sidebar "New File" / "New Folder" (`resolveUniqueName`): `{base}{ext}`,
    /// then `{base} 2{ext}` … up to 999.
    public static func uniqueName(in parent: String, base: String, ext: String, exists: (String) -> Bool = WorkspaceFS.exists) throws -> String {
        let first = "\(parent)/\(base)\(ext)"
        if !exists(first) { return first }
        for n in 2..<1000 {
            let candidate = "\(parent)/\(base) \(n)\(ext)"
            if !exists(candidate) { return candidate }
        }
        throw AppError.io("Could not find an available name for \"\(base)\" in \(parent)")
    }

    public static func newFilePath(in parent: String, exists: (String) -> Bool = WorkspaceFS.exists) throws -> String {
        try uniqueName(in: parent, base: L("Untitled"), ext: ".md", exists: exists)
    }

    public static func newFolderPath(in parent: String, exists: (String) -> Bool = WorkspaceFS.exists) throws -> String {
        try uniqueName(in: parent, base: L("Untitled Folder"), ext: "", exists: exists)
    }

    /// Duplicate naming (`resolveDuplicatePath`): `note copy.md`, `note copy 2.md`, ….
    public static func duplicatePath(for source: String, exists: (String) -> Bool = WorkspaceFS.exists) throws -> String {
        let normalized = source.replacingOccurrences(of: "\\", with: "/")
        let parent = LinkPaths.getParentDir(normalized)
        let name = normalized.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { ext = String(name[dot...]) } else { ext = "" }
        let stem = LinkPaths.getFileStem(source)
        let copy = L("copy")  // Finder-style "note copy.md"
        let first = "\(parent)/\(stem) \(copy)\(ext)"
        if !exists(first) { return first }
        for n in 2..<1000 {
            let candidate = "\(parent)/\(stem) \(copy) \(n)\(ext)"
            if !exists(candidate) { return candidate }
        }
        throw AppError.io("Could not find an available duplicate name for \(source)")
    }

    /// Command palette create mode (`toCreatePath`): `.md` appended unless present.
    public static func paletteCreatePath(root: String, rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fileName = trimmed.hasSuffix(".md") ? trimmed : "\(trimmed).md"
        return "\(root)/\(fileName)"
    }

    // MARK: Images

    public static let attachmentsDir = "attachments"
    public static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp"]

    /// Files a tab shows in a viewer instead of the text editor (never read or saved as text).
    public enum ViewerKind { case pdf, image }
    public static func viewerKind(_ path: String) -> ViewerKind? {
        if rustExtension(path)?.lowercased() == "pdf" { return .pdf }
        return isImagePath(path) ? .image : nil
    }

    /// Dropped files embedded in the note like images (PDFs render as a one-page card).
    public static func isEmbeddablePath(_ path: String) -> Bool {
        isImagePath(path) || rustExtension(path)?.lowercased() == "pdf"
    }

    public static func isImagePath(_ path: String) -> Bool {
        guard let ext = rustExtension(path) else { return false }
        return imageExtensions.contains { $0.caseInsensitiveCompare(ext) == .orderedSame }
    }

    /// `YYYYMMDD-HHMMSS-xxxx.ext` in UTC; `xxxx` is the first 4 hex chars of a v4 UUID.
    public static func clipboardImageFileName(date: Date, format: String, uuid: UUID = UUID()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let ext: String
        switch format {
        case "jpeg", "jpg": ext = "jpg"
        case "webp": ext = "webp"
        default: ext = "png"
        }
        let short = String(uuid.uuidString.lowercased().prefix(4))
        return String(format: "%04d%02d%02d-%02d%02d%02d-", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!) + short + "." + ext
    }

    /// `save_clipboard_image_impl`: writes into `attachments/` beside the note.
    public static func saveClipboardImage(markdownFilePath: String, data: Data, format: String, now: Date = Date()) throws -> ImageSaveResult {
        let mdDir = (markdownFilePath as NSString).deletingLastPathComponent
        let assets = (mdDir as NSString).appendingPathComponent(attachmentsDir)
        let fileName = clipboardImageFileName(date: now, format: format)
        let abs = (assets as NSString).appendingPathComponent(fileName)
        do {
            try fm.createDirectory(atPath: assets, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: abs))
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        return ImageSaveResult(relativePath: "\(attachmentsDir)/\(fileName)", absolutePath: abs)
    }

    /// `import_image_file_impl`: copies into `attachments/`, keeping the name
    /// and adding `-1`, `-2`, … on collision.
    public static func importImageFile(markdownFilePath: String, sourcePath: String) throws -> ImageSaveResult {
        guard isFile(sourcePath) else { throw AppError.notFound(sourcePath) }
        let mdDir = (markdownFilePath as NSString).deletingLastPathComponent
        let assets = (mdDir as NSString).appendingPathComponent(attachmentsDir)
        do { try fm.createDirectory(atPath: assets, withIntermediateDirectories: true) } catch { throw AppError.io(error.localizedDescription) }
        let stem = rustFileStem(sourcePath)
        let ext = rustExtension(sourcePath) ?? "png"
        var fileName = "\(stem).\(ext)"
        var counter = 1
        while exists((assets as NSString).appendingPathComponent(fileName)) {
            fileName = "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        let abs = (assets as NSString).appendingPathComponent(fileName)
        do { try fm.copyItem(atPath: sourcePath, toPath: abs) } catch { throw AppError.io(error.localizedDescription) }
        return ImageSaveResult(relativePath: "\(attachmentsDir)/\(fileName)", absolutePath: abs)
    }

    // MARK: Workspace root

    /// `canonicalize_workspace_root`: must exist and be a directory; resolves
    /// symlinks (`/var` → `/private/var`).
    public static func canonicalizeWorkspaceRoot(_ path: String) throws -> String {
        guard isDirectory(path) else { throw AppError.notFound(path) }
        guard let real = realpath(path, nil) else { throw AppError.io("canonicalize failed") }
        defer { free(real) }
        return String(cString: real)
    }

    /// Canonical path when resolvable, else the input.
    public static func canonicalize(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}
