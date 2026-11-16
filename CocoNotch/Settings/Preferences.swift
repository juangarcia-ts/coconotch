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
