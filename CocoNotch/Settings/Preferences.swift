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

extension Color {
    /// Restores a color saved with `encodeColorData`; black when nothing usable was saved.
    init(colorData: Data) {
        self = (try? JSONDecoder().decode(Color.Resolved.self, from: colorData)).map(Color.init) ?? .black
    }

    func encodeColorData(in environment: EnvironmentValues) -> Data {
        (try? JSONEncoder().encode(resolve(in: environment))) ?? Data()
    }
}
