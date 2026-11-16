import SwiftUI

struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let makeView: () -> AnyView
    /// Settings shown under the widget's submenu in the menu bar; nil hides the submenu.
    var makeMenuItems: (() -> AnyView)? = nil

    // Tabs appear in this order.
    static let all: [NotchWidget] = [.timezones]
}
