import Foundation
import Darwin

/// FLO_TRACE_LAUNCH=<file>: append launch phase timings (ms since the process started).
/// FLO_DATA_DIR=<dir>: use another app-data folder and skip single-instance forwarding
/// (measure a copy without touching the running app). FLO_TRACE_EXIT=1 quits after the first
/// editor has drawn.
enum LaunchTrace {
    static let path = ProcessInfo.processInfo.environment["FLO_TRACE_LAUNCH"]
    static var enabled: Bool { path != nil }
    private static let processStart: Double = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }()
    private static var marked = Set<String>()

    /// A duration line (not deduplicated): "<start ms> +<dur ms>  what".
    static func note(_ what: String, since t0: Date) {
        guard let p = path else { return }
        let start = (t0.timeIntervalSince1970 - processStart) * 1000, dur = Date().timeIntervalSince(t0) * 1000
        let line = String(format: "%7.1f ms  +%6.1f  %@\n", start, dur, what)
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    }

    static func mark(_ phase: String) {
        guard let p = path, !marked.contains(phase) else { return }
        marked.insert(phase)
        let ms = (Date().timeIntervalSince1970 - processStart) * 1000
        let line = String(format: "%7.1f ms  %@\n", ms, phase)
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { FileManager.default.createFile(atPath: p, contents: Data(line.utf8)) }
    }
}
