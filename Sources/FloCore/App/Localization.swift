import Foundation

/// UI strings. The English source text is the key; translations live in
/// FloCore's resource bundle (`Resources/<lang>.lproj/Localizable.strings`),
/// picked by the bundle from the user's (or per-app) language list. A missing
/// key falls back to the English key, so English needs no lookup table hits.
public enum L10n {
    /// Where the tables come from. Tests may point this at one `<lang>.lproj`.
    nonisolated(unsafe) public static var bundle: Bundle = FloResources.bundle

    /// Languages shipped (lproj names), English first.
    public static let languages = ["en", "zh-Hans", "fr", "es", "it", "ja", "de", "hi", "bn", "pt-BR", "pt-PT", "ru", "ur", "ar"]

    public static func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }

    /// One language's table bundle (`<lang>.lproj`), for tests and snapshots.
    public static func languageBundle(_ lang: String) -> Bundle? {
        FloResources.bundle.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// The language the UI strings resolve to (e.g. "de"; "en" when none matches).
    public static var current: String { bundle.preferredLocalizations.first ?? "en" }
}

/// Localized UI text; `key` is the English source string.
@inline(__always) public func L(_ key: String) -> String { L10n.string(key) }

/// Localized format string (`%@`, `%d`, `%1$@`…) filled with `args`.
public func L(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.string(key), arguments: args) }
