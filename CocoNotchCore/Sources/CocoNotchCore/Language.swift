import Foundation

/// The macOS defaults key that holds an app's own language order; it overrides the system order for that app.
public let appLanguagesKey = "AppleLanguages"

/// A language's name in that language, such as "Deutsch" or "日本語", so anyone can find their own.
public func formatLanguageName(_ identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    let name = locale.localizedString(forIdentifier: identifier) ?? identifier
    return name.prefix(1).uppercased(with: locale) + name.dropFirst()
}

/// The languages the app ships, without Xcode's "Base", sorted by their own names.
public func getAppLanguages(localizations: [String]) -> [String] {
    localizations.filter { $0 != "Base" }.sorted {
        formatLanguageName($0).localizedStandardCompare(formatLanguageName($1)) == .orderedAscending
    }
}

/// The language the app runs in for a choice: `chosen`, or nil to follow the system's order.
public func resolveAppLanguage(chosen: String?, systemLanguages: [String], available: [String]) -> String? {
    Bundle.preferredLocalizations(from: available, forPreferences: chosen.map { [$0] } ?? systemLanguages).first
}
