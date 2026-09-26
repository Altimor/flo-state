import AppKit
import FloCore

/// The `writer` shell command (port of `writer_cli.rs` + `shell_install.rs`).
/// The app binary is itself the CLI: when invoked as `writer` (argv[0]
/// basename), it opens its argument in the app and exits. "Install" symlinks
/// /usr/local/bin/writer → the running binary inside the bundle.
enum WriterCLI {
    static let installTarget = "/usr/local/bin/writer"
    static let exitSuccess: Int32 = 0, exitUsage: Int32 = 2, exitRuntime: Int32 = 3

    static let usage = """
    Usage: writer [PATH]

    Open a folder or markdown file in the Flo State desktop app.

    Arguments:
      PATH              Directory or .md/.markdown file to open. If omitted,
                        Flo State launches with no target.

    Options:
      -h, --help        Print this help and exit.
      -V, --version     Print version and exit.

    Environment:
      WRITER_APP_PATH   Override the path to the app bundle (development builds).
    """

    enum Parsed: Equatable { case help, version, open(String?) }
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownFlag(String), tooManyArgs
        var description: String {
            switch self {
            case let .unknownFlag(f): return "unknown option: \(f)"
            case .tooManyArgs: return "expected at most one path argument"
            }
        }
    }

    static func isCLIInvocation(_ argv0: String) -> Bool {
        (argv0 as NSString).lastPathComponent == "writer"
    }

    static func parse(_ argv: [String]) -> Result<Parsed, ParseError> {
        var positional: String?
        for a in argv.dropFirst() {
            switch a {
            case "--help", "-h": return .success(.help)
            case "--version", "-V": return .success(.version)
            default:
                if a.hasPrefix("-") { return .failure(.unknownFlag(a)) }
                if positional != nil { return .failure(.tooManyArgs) }
                positional = a
            }
        }
        return .success(.open(positional))
    }

    /// The app bundle containing `binary` (…/X.app/Contents/MacOS/bin).
    static func bundlePath(forBinary binary: String) -> String? {
        var p = (binary as NSString).resolvingSymlinksInPath
        for _ in 0..<3 { p = (p as NSString).deletingLastPathComponent }
        return p.hasSuffix(".app") ? p : nil
    }

    /// Run as the CLI. `launch` receives the `open` arguments (injectable for tests).
    static func run(_ argv: [String], cwd: String, out: (String) -> Void = { print($0) }, err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                    env: [String: String] = ProcessInfo.processInfo.environment,
                    launch: ([String]) -> Bool = { args in
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        p.arguments = args
                        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
                    }) -> Int32 {
        switch parse(argv) {
        case .success(.help): out(usage); return exitSuccess
        case .success(.version):
            out("writer \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
            return exitSuccess
        case let .failure(e):
            err("writer: \(e)\n\n\(usage)")
            return exitUsage
        case let .success(.open(path)):
            var target: String?
            if let p = path {
                let abs = p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
                let std = (abs as NSString).standardizingPath
                guard FileManager.default.fileExists(atPath: std) else { err("writer: no such file or directory: \(std)"); return exitRuntime }
                guard let pending = PendingOpen.resolve(std) else { err("writer: not a folder or markdown file: \(std)"); return exitRuntime }
                target = pending.file ?? pending.workspace
            }
            let app = env["WRITER_APP_PATH"] ?? bundlePath(forBinary: argv.first.map(resolveArgv0) ?? "") ?? "Flo State"
            var args = ["-a", app]
            if let t = target { args.append(t) }
            guard launch(args) else { err("writer: could not launch Flo State (\(app)). Set WRITER_APP_PATH."); return exitRuntime }
            return exitSuccess
        }
    }

    /// argv[0] may be a bare name found through PATH.
    static func resolveArgv0(_ a: String) -> String {
        if a.contains("/") { return a }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/\(a)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return a
    }

    // MARK: install / uninstall

    enum State: Equatable { case missing, installed, stale, foreign }

    static func state(target: String = installTarget, source: String?) -> State {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: target) else {
            // a dangling symlink has no attributes via the target: check the link itself
            if (try? fm.destinationOfSymbolicLink(atPath: target)) != nil { return .stale }
            return .missing
        }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink || (try? fm.destinationOfSymbolicLink(atPath: target)) != nil else { return .foreign }
        guard let link = try? fm.destinationOfSymbolicLink(atPath: target) else { return .foreign }
        if let s = source, (link as NSString).resolvingSymlinksInPath == (s as NSString).resolvingSymlinksInPath { return .installed }
        return .stale
    }

    static var sourceBinary: String? { Bundle.main.executablePath }

    enum InstallError: Error, CustomStringConvertible {
        case occupied(String), failed(String)
        var description: String {
            switch self {
            case let .occupied(p): return "\(p) already exists and is not a symlink. Remove it manually if you want Flo State to manage it."
            case let .failed(m): return m
            }
        }
    }

    /// Symlink directly, else ask for administrator rights (same as legacy).
    static func install(source: String, target: String = installTarget, elevate: (String) -> Bool = runPrivileged) throws {
        let fm = FileManager.default
        if state(target: target, source: source) == .foreign { throw InstallError.occupied(target) }
        let parent = (target as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: target)) != nil { try fm.removeItem(atPath: target) }
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
        } catch {
            let cmd = "mkdir -p \(shq(parent)) && rm -f \(shq(target)) && ln -s \(shq(source)) \(shq(target))"
            if !elevate(cmd) { throw InstallError.failed("administrator authorization failed or was cancelled") }
        }
    }

    static func uninstall(source: String?, target: String = installTarget, elevate: (String) -> Bool = runPrivileged) throws {
        switch state(target: target, source: source) {
        case .missing: return
        case .foreign: throw InstallError.occupied(target)
        case .installed, .stale:
            do { try FileManager.default.removeItem(atPath: target) } catch {
                if !elevate("rm -f \(shq(target))") { throw InstallError.failed("administrator authorization failed or was cancelled") }
            }
        }
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func runPrivileged(_ shell: String) -> Bool {
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }

    static let installLabel = "Install 'writer' Command Line Tool…"
    static let uninstallLabel = "Uninstall 'writer' Command Line Tool…"
}

/// The app-menu item that toggles the CLI install (label follows the state).
@MainActor
final class CLIMenuItem: NSMenuItem {
    init() {
        super.init(title: WriterCLI.installLabel, action: #selector(toggle), keyEquivalent: "")
        target = self
        refresh()
    }
    required init(coder: NSCoder) { fatalError() }

    func refresh() {
        title = WriterCLI.state(source: WriterCLI.sourceBinary) == .installed ? WriterCLI.uninstallLabel : WriterCLI.installLabel
    }

    @objc func toggle() {
        guard let src = WriterCLI.sourceBinary else { return }
        let installed = WriterCLI.state(source: src) == .installed
        let alert = NSAlert()
        do {
            if installed {
                try WriterCLI.uninstall(source: src)
                alert.messageText = "Writer CLI Removed"
                alert.informativeText = "The `writer` command has been removed from \(WriterCLI.installTarget)."
            } else {
                try WriterCLI.install(source: src)
                alert.messageText = "Writer CLI Installed"
                alert.informativeText = "The `writer` command is now installed at \(WriterCLI.installTarget).\n\nRun `writer .` from any terminal to open the current folder."
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Writer CLI"
            alert.informativeText = (installed ? "Could not remove the writer command.\n\n" : "Could not install the writer command.\n\n") + "\(error)"
        }
        refresh()
        alert.runModal()
    }
}
