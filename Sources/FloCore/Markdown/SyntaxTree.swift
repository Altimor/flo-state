import Foundation

/// A node in the markdown syntax tree. Positions are UTF-16 offsets into the
/// document (identical to JavaScript string indices and NSString ranges), so
/// fixtures from the web app compare 1:1.
public final class SyntaxNode {
    public let name: String
    public let from: Int
    public let to: Int
    public internal(set) var children: [SyntaxNode]
    public internal(set) weak var parent: SyntaxNode?

    public init(name: String, from: Int, to: Int, children: [SyntaxNode] = []) {
        self.name = name
        self.from = from
        self.to = to
        self.children = children
        for c in children { c.parent = self }
    }

    public var range: NSRange { NSRange(location: from, length: to - from) }
}

public struct SyntaxTree {
    public let root: SyntaxNode
    public init(root: SyntaxNode) { self.root = root }

    /// Pre-order walk. Return false from `enter` to skip a node's children.
    public func iterate(from: Int = 0, to: Int = Int.max,
                        enter: (SyntaxNode, Int) -> Bool, leave: ((SyntaxNode) -> Void)? = nil) {
        func walk(_ n: SyntaxNode, _ depth: Int) {
            guard n.to >= from, n.from <= to else { return }
            if enter(n, depth) {
                for c in n.children { walk(c, depth + 1) }
            }
            leave?(n)
        }
        walk(root, 0)
    }

    /// Same shape as the oracle's `__flo.dumpTree()`: [name, from, to, depth].
    public func dump() -> [(String, Int, Int, Int)] {
        var out: [(String, Int, Int, Int)] = []
        iterate(enter: { n, d in out.append((n.name, n.from, n.to, d)); return true })
        return out
    }

    /// Innermost node covering `pos` (side -1 = prefer node ending at pos, 1 = starting).
    public func resolveInner(_ pos: Int, side: Int = 0) -> SyntaxNode {
        var cur = root
        outer: while true {
            for c in cur.children {
                let inside: Bool
                switch side {
                case -1: inside = c.from < pos && c.to >= pos
                case 1: inside = c.from <= pos && c.to > pos
                default: inside = c.from <= pos && c.to >= pos
                }
                if inside { cur = c; continue outer }
            }
            return cur
        }
    }
}
