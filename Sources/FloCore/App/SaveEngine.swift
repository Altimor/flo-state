import Foundation

/// What the save engine needs to read from / report to the editor store
/// (`save.ts::SaveStoreAccess`).
@MainActor
public protocol SaveEngineHost: AnyObject {
    /// Current in-memory state of an open file, nil when not open.
    func fileForSave(_ path: String) -> (frontmatter: String?, content: String, isDirty: Bool)?
    func markSaved(_ path: String, diskContent: String, hasNewerChanges: Bool)
    func setSaveError(_ path: String, error: String)
}

/// Save-time text processing (`applyFileProcessing`).
public struct SaveProcessing: Equatable {
    public var trimTrailingWhitespace: Bool
    public var insertFinalNewline: Bool
    public init(trimTrailingWhitespace: Bool = false, insertFinalNewline: Bool = true) {
        self.trimTrailingWhitespace = trimTrailingWhitespace
        self.insertFinalNewline = insertFinalNewline
    }

    public init(settings: SettingsValues) {
        self.init(trimTrailingWhitespace: settings.filesTrimTrailingWhitespace, insertFinalNewline: settings.filesInsertFinalNewline)
    }

    /// Trim: JS `/\s+$/` per `\n`-split line (so a trailing `\r` goes too).
    /// Final newline: append `\n` when missing (also to an empty document).
    public func apply(_ content: String) -> String {
        var result = content
        if trimTrailingWhitespace {
            result = result.components(separatedBy: "\n").map { AppRegex.replace($0, "\(AppRegex.ws)+$", "") }.joined(separator: "\n")
        }
        if insertFinalNewline && result.utf8.last != 0x0A { result += "\n" }
        return result
    }
}

/// Autosave engine (port of `src/lib/save.ts`): per-path 1000 ms throttle,
/// one write in flight per path, follow-up save when edits land during a
/// write. Writes are callback-based so tests can hold them open.
@MainActor
public final class SaveEngine {
    public static let throttleMs: Double = 1000

    public typealias Writer = @MainActor (_ path: String, _ content: String, _ completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> Void

    final class Controller {
        var lastSaveTime: Double = 0
        var timer: ScheduledToken?
        var inFlight = false
        var pending = false
    }

    public weak var host: SaveEngineHost?
    private let scheduler: AppScheduler
    private let writer: Writer
    private let processing: () -> SaveProcessing
    private var controllers: [String: Controller] = [:]

    public init(scheduler: AppScheduler, processing: @escaping () -> SaveProcessing, writer: @escaping Writer) {
        self.scheduler = scheduler
        self.processing = processing
        self.writer = writer
    }

    private func controller(_ path: String) -> Controller {
        if let c = controllers[path] { return c }
        let c = Controller()
        controllers[path] = c
        return c
    }

    private func clearTimer(_ c: Controller) {
        if let t = c.timer { scheduler.cancel(t); c.timer = nil }
    }

    private func cleanup(_ path: String, _ c: Controller) {
        if c.inFlight || c.pending || c.timer != nil { return }
        controllers[path] = nil
    }

    /// `scheduleSave`.
    public func scheduleSave(_ path: String) {
        let c = controller(path)
        c.pending = true
        queue(path, c)
    }

    public func isSaveInFlight(_ path: String) -> Bool { controllers[path]?.inFlight == true }

    /// Whether any state (timer, pending, in-flight) exists for `path`.
    public func hasController(_ path: String) -> Bool { controllers[path] != nil }

    public func hasPendingTimer(_ path: String) -> Bool { controllers[path]?.timer != nil }

    /// `cancelSave`.
    public func cancelSave(_ path: String) {
        guard let c = controllers[path] else { return }
        c.pending = false
        clearTimer(c)
        cleanup(path, c)
    }

    private func queue(_ path: String, _ c: Controller) {
        if c.inFlight { return }
        clearTimer(c)
        let elapsed = scheduler.nowMs - c.lastSaveTime
        if elapsed >= SaveEngine.throttleMs {
            performSave(path, c)
            return
        }
        c.timer = scheduler.schedule(afterMs: SaveEngine.throttleMs - elapsed) { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            c.timer = nil
            self.performSave(path, c)
        }
    }

    public func serializeForSave(frontmatter: String?, content: String) -> String {
        processing().apply(Frontmatter.serialize(frontmatter, body: content))
    }

    private func performSave(_ path: String, _ c: Controller) {
        if c.inFlight { return }
        guard let host = host, let file = host.fileForSave(path), file.isDirty else {
            c.pending = false
            cleanup(path, c)
            return
        }
        c.inFlight = true
        c.pending = false
        c.lastSaveTime = scheduler.nowMs
        let full = serializeForSave(frontmatter: file.frontmatter, content: file.content)
        writer(path, full) { [weak self] result in
            guard let self = self else { return }
            var shouldReschedule = false
            switch result {
            case .success:
                if let latest = self.host?.fileForSave(path) {
                    shouldReschedule = self.serializeForSave(frontmatter: latest.frontmatter, content: latest.content) != full
                    self.host?.markSaved(path, diskContent: full, hasNewerChanges: shouldReschedule)
                }
            case let .failure(error):
                self.host?.setSaveError(path, error: String(describing: error))
            }
            c.inFlight = false
            if c.pending || shouldReschedule {
                self.queue(path, c)
            } else {
                self.cleanup(path, c)
            }
        }
    }
}
