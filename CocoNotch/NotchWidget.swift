import SwiftUI

struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let makeView: () -> AnyView
    /// The widget's tab in the Settings window; nil means the widget has no tab.
    var makeSettings: (() -> AnyView)? = nil

    // Tabs appear in this order.
    static let all: [NotchWidget] = [.timezones]
}
