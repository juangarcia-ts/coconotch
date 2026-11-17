import SwiftUI

enum BackgroundStyle: String {
    case solid
    case blur
}

enum PreferenceKey {
    static let backgroundStyle = "appearance.backgroundStyle"
    static let backgroundColor = "appearance.backgroundColor"
    static let backgroundOpacity = "appearance.backgroundOpacity"
    static let expandsOnClick = "behavior.expandsOnClick"
    static let widgetPreferences = "widgets.preferences"
    static let selectedWidget = "selectedWidget"
    static let showsHome = "widgets.showsHome"
    static let notchDisplay = "behavior.notchDisplay"
    static let notchScale = "appearance.notchScale"
    static let showsActivities = "behavior.showsActivities"
    /// A widget ID whose activity always wins the closed notch, or "" to rank them automatically.
    static let preferredActivityWidget = "behavior.preferredActivityWidget"
    static let staysOpenWhileTyping = "behavior.staysOpenWhileTyping"
    static let widgetShortcuts = "behavior.widgetShortcuts"
}

extension Color.Resolved {
    /// Restores a color saved with `Color.encodeColorData`; black when nothing usable was saved.
    static func decode(colorData: Data) -> Color.Resolved {
        (try? JSONDecoder().decode(Color.Resolved.self, from: colorData)) ?? Color.Resolved(red: 0, green: 0, blue: 0)
    }
}

extension Color {
    init(colorData: Data) {
        self.init(Color.Resolved.decode(colorData: colorData))
    }

    func encodeColorData(in environment: EnvironmentValues) -> Data {
        (try? JSONEncoder().encode(resolve(in: environment))) ?? Data()
    }
}
