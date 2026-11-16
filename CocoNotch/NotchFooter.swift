import CocoNotchCore
import SwiftUI

private let repositoryURL = URL(string: "https://github.com/juangarcia-ts/coconotch")
private let coffeeURL = URL(string: "https://buymeacoffee.com/juangarciats")

/// The quiet line under every widget: the app's version, and links to its repository and to support it.
struct NotchFooter: View {
    /// The footer's whole height, its spacing included, so the widget above can be sized to leave room for it.
    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            if let version = formatAppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) {
                Text(version)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let repositoryURL {
                FooterLink(url: repositoryURL, help: "CocoNotch on GitHub") {
                    Image("GitHub")
                        .resizable()
                        .frame(width: 11, height: 11)
                }
            }
            if let coffeeURL {
                FooterLink(url: coffeeURL, help: "Support CocoNotch") {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
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
    let url: URL
    let help: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Link(destination: url) { content }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help(help)
    }
}
