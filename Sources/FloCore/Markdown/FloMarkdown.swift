import Foundation

/// Markdown parser producing the same syntax tree as Flo State's web editor
/// (@lezer/markdown 1.6.3 + GFM + the prosemark and HTML-block extensions).
public enum FloMarkdown {
    public static func parse(_ text: String) -> SyntaxTree {
        parse(units: Array(text.utf16))
    }

    public static func parse(units input: [UInt16]) -> SyntaxTree {
        let doc = MDBlockContext(input).parse()
        return SyntaxTree(root: doc.toSyntaxNode())
    }
}
