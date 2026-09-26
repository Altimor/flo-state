import Foundation

/// One entry of `settings.schema.json` (port of `config.rs::SettingDef`).
public struct SettingDef: Equatable {
    public enum ValueType: String { case string, number, boolean, `enum`, list, color, range, font }

    public let key: String
    public let label: String
    public let description: String
    public let category: String
    public let type: ValueType
    public let options: [String]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let cssVar: String?
    public let cssFormat: String?
    public let defaultValue: ConfigValue
}

public enum SettingsSchema {
    /// All schema entries in file order.
    public static let all: [SettingDef] = load()

    public static let byKey: [String: SettingDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// `default_settings()`.
    public static var defaults: [String: ConfigValue] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.defaultValue) })
    }

    public static func def(_ key: String) -> SettingDef? { byKey[key] }

    static func resourceURL(_ name: String, ext: String, subdirectory: String? = nil) -> URL? {
        let sub = subdirectory.map { "Resources/\($0)" } ?? "Resources"
        return FloResources.bundle.url(forResource: name, withExtension: ext, subdirectory: sub)
    }

    private static func load() -> [SettingDef] {
        guard let url = resourceURL("settings.schema", ext: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSON.parse(data: data),
              let settings = root["settings"]?.arrayValue
        else {
            fatalError("settings.schema.json is missing or malformed")
        }
        return settings.map { entry in
            let defaultValue: ConfigValue
            switch entry["default"] ?? .null {
            case let .bool(b): defaultValue = .bool(b)
            case let .int(i): defaultValue = .number(Double(i))
            case let .double(d): defaultValue = .number(d)
            case let .string(s): defaultValue = .string(s)
            case let .array(a): defaultValue = .list(a.compactMap { $0.stringValue })
            default: fatalError("settings.schema.json: bad default for \(entry["key"]?.stringValue ?? "?")")
            }
            return SettingDef(
                key: entry["key"]?.stringValue ?? "",
                label: entry["label"]?.stringValue ?? "",
                description: entry["description"]?.stringValue ?? "",
                category: entry["category"]?.stringValue ?? "",
                type: SettingDef.ValueType(rawValue: entry["type"]?.stringValue ?? "string") ?? .string,
                options: entry["options"]?.arrayValue?.compactMap { $0.stringValue },
                min: entry["min"]?.doubleValue,
                max: entry["max"]?.doubleValue,
                step: entry["step"]?.doubleValue,
                cssVar: entry["cssVar"]?.stringValue,
                cssFormat: entry["cssFormat"]?.stringValue,
                defaultValue: defaultValue
            )
        }
    }

    /// Editable theme primaries for a mode (`getPrimaryDefs`): every
    /// `theme.{mode}.*` key except `preset`, in schema order.
    public static func primaryDefs(_ mode: ThemeMode) -> [SettingDef] {
        let prefix = "theme.\(mode.rawValue)."
        return all.filter { $0.key.hasPrefix(prefix) && $0.key != "\(prefix)preset" }
    }

    /// CSS-var bindings for non-theme settings (`applyCssVarBindings`):
    /// `(cssVar, formatted value)` for every bound key with a string/number value.
    public static func cssVarBindings(_ settings: [String: ConfigValue]) -> [(String, String)] {
        var out: [(String, String)] = []
        for def in all {
            guard let cssVar = def.cssVar, !def.key.hasPrefix("theme.") else { continue }
            guard let value = settings[def.key], let formatted = formatCssValue(value, def.cssFormat) else { continue }
            out.append((cssVar, formatted))
        }
        return out
    }

    /// `formatCssValue`: strings verbatim, numbers via JS `toString`, `px` appends the unit.
    public static func formatCssValue(_ value: ConfigValue, _ format: String?) -> String? {
        let str: String
        switch value {
        case let .string(s): str = s
        case let .number(n): str = jsNumberString(n)
        default: return nil
        }
        return format == "px" ? "\(str)px" : str
    }

    /// JS `Number.prototype.toString` for the ranges settings use.
    public static func jsNumberString(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
        if n == n.rounded(), abs(n) < 1e21 { return ConfigFile.rustDisplay(n) }
        let abs = Swift.abs(n)
        if abs >= 1e-6 && abs < 1e21 { return ConfigFile.rustDisplay(n) }
        return "\(n)"
    }
}
