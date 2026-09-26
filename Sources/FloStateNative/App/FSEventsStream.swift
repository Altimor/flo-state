import CoreServices
import FloCore
import Foundation

/// FSEvents (file-level) → `RawFSEvent`, delivered on the main queue.
final class FSEventsStream {
    private var stream: FSEventStreamRef?
    private let handler: ([RawFSEvent]) -> Void

    init?(path: String, latency: CFTimeInterval = 0.05, handler: @escaping @MainActor ([RawFSEvent]) -> Void) {
        self.handler = { events in MainActor.assumeIsolated { handler(events) } }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let me = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var out: [RawFSEvent] = []
            for i in 0..<count where i < arr.count {
                out.append(FSEventsStream.map(path: arr[i], flags: flags[i]))
            }
            me.handler(out)
        }, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    /// Flags accumulate over the coalescing window, so the current state on
    /// disk decides between created/removed.
    static func map(path: String, flags: FSEventStreamEventFlags, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> RawFSEvent {
        func has(_ f: Int) -> Bool { flags & FSEventStreamEventFlags(f) != 0 }
        let isDir = has(kFSEventStreamEventFlagItemIsDir)
        let present = exists(path)
        let kind: RawFSEvent.Kind
        if has(kFSEventStreamEventFlagItemRenamed) {
            kind = .modifiedName
        } else if has(kFSEventStreamEventFlagItemRemoved) && !present {
            kind = isDir ? .removedFolder : .removed
        } else if has(kFSEventStreamEventFlagItemCreated) && !has(kFSEventStreamEventFlagItemModified) {
            kind = isDir ? .createdFolder : .created
        } else if has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemInodeMetaMod) {
            kind = .modifiedData
        } else if has(kFSEventStreamEventFlagItemCreated) {
            kind = isDir ? .createdFolder : .created
        } else {
            kind = .modifiedOther
        }
        return RawFSEvent(kind: kind, paths: [path])
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
