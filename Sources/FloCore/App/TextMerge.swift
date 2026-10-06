import Foundation

/// Line-based three-way merge (diff3): the note as this device last read it (`base`), this device's
/// edits (`ours`) and what is on disk now (`theirs`, e.g. just synced from the Mac). Changes to
/// different lines combine; where both sides changed the same lines, both versions are kept (ours,
/// then theirs), so no one's text is ever dropped.
public enum TextMerge {
    public static func merge3(base: String, ours: String, theirs: String) -> String {
        if ours == theirs || theirs == base { return ours }
        if ours == base { return theirs }
        let a = lines(base), o = lines(ours), t = lines(theirs)
        let mo = matches(a, o), mt = matches(a, t)   // base index -> index in ours / theirs
        var out: [Substring] = []
        var ai = 0, oi = 0, ti = 0
        func chunk() {
            // up to the next base line both sides kept unchanged (a sync point)
            var s = ai
            while s < a.count, !(mo[s] != nil && mt[s] != nil) { s += 1 }
            let oEnd = s < a.count ? mo[s]! : o.count, tEnd = s < a.count ? mt[s]! : t.count
            let A = Array(a[ai..<s]), O = Array(o[oi..<oEnd]), T = Array(t[ti..<tEnd])
            if O == A { out += T } else if T == A || O == T { out += O } else { out += O; out += T }
            ai = s; oi = oEnd; ti = tEnd
        }
        while ai < a.count || oi < o.count || ti < t.count {
            if ai < a.count, mo[ai] == oi, mt[ai] == ti {
                out.append(a[ai]); ai += 1; oi += 1; ti += 1
            } else {
                chunk()
                if ai >= a.count, oi >= o.count, ti >= t.count { break }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func lines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }

    /// For each base line kept (not removed) in `other`, its index there (LCS alignment).
    private static func matches(_ base: [Substring], _ other: [Substring]) -> [Int?] {
        let diff = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let off, _, _): removed.insert(off)
            case .insert(let off, _, _): inserted.insert(off)
            }
        }
        var map = [Int?](repeating: nil, count: base.count)
        var j = 0
        for i in 0..<base.count where !removed.contains(i) {
            while inserted.contains(j) { j += 1 }
            map[i] = j
            j += 1
        }
        return map
    }
}
