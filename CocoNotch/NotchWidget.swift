import CocoNotchCore
import SwiftUI

struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let makeView: () -> AnyView
    /// The widget's tab in the Settings window; nil means the widget has no tab.
    var makeSettings: (() -> AnyView)? = nil

    // The default order; users can reorder and switch widgets off in Settings → Widgets.
    static let all: [NotchWidget] = [.timezones, .meetings]

    static func find(id: String) -> NotchWidget? {
        all.first { $0.id == id }
    }

    /// Every widget in the user's saved order, with whether it is switched on.
    static func getPreferences(stored: String) -> [WidgetPreference] {
        decodeWidgetPreferences(stored, availableIDs: all.map(\.id))
    }
}
