import CocoNotchCore
import SwiftUI

struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let makeView: () -> AnyView
    /// The widget's tab in the Settings window; nil means the widget has no tab.
    var makeSettings: (() -> AnyView)? = nil
    /// A compact view for the Home tab; nil means the widget has no summary.
    var makeSummary: (() -> AnyView)? = nil
    /// Settings for the summary, shown under its switch in Settings → Home.
    var makeSummarySettings: (() -> AnyView)? = nil

    // The default order; users can reorder and switch widgets off in Settings → Widgets. Home is always first, so
    // it isn't in this list.
    static let all: [NotchWidget] = [.timezones, .meetings, .weather, .aiUsage, .music, .system]

    static var summaryIDs: Set<String> {
        Set(all.filter { $0.makeSummary != nil }.map(\.id))
    }

    static func find(id: String) -> NotchWidget? {
        ([.home] + all).first { $0.id == id }
    }

    /// Every widget in the user's saved order, with whether it is switched on.
    static func getPreferences(stored: String) -> [WidgetPreference] {
        decodeWidgetPreferences(stored, availableIDs: all.map(\.id))
    }
}
