import CocoNotchCore
import SwiftUI

private let repositoryURL = URL(string: "https://github.com/juangarcia-ts/coconotch")
private let coffeeURL = URL(string: "https://buymeacoffee.com/juangarciats")

/// The quiet line under every widget: the version, linking to the repository, a link to support the app and Settings.
struct NotchFooter: View {
    /// The footer's whole height, its spacing included, so the widget above can be sized to leave room for it.
    static let height: CGFloat = 40
    @Environment(\.openURL) private var openURL
    @Environment(\.showSettings) private var showSettings

    var body: some View {
        HStack(spacing: 14) {
            if let repositoryURL {
                FooterLink(help: "CocoNotch on GitHub") {
                    openURL(repositoryURL)
                } label: {
                    HStack(spacing: 5) {
                        Image("GitHub")
                            .resizable()
                            .frame(width: 11, height: 11)
                        Text(
                            formatAppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                                ?? "CocoNotch"
                        )
                    }
                }
            }
            Spacer()
            if let coffeeURL {
                FooterLink(help: "Support CocoNotch") {
                    openURL(coffeeURL)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
            }
            // Here rather than in the tab row, so it doesn't read as one more widget.
            FooterLink(help: "Settings") {
                showSettings(.general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .font(.caption2)
        .frame(height: 16)
        // Clear air above, so the line reads as separate from the widget rather than part of it.
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

private struct FooterLink<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help(help)
    }
}
