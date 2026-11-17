import AppKit
import SwiftUI

/// What a widget shows when it can't work yet, such as a missing permission: its icon, why, and the fix.
struct WidgetPrompt<Actions: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

extension WidgetPrompt where Actions == EmptyView {
    init(systemImage: String, message: String) {
        self.init(systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// Opens a pane of System Settings → Privacy & Security, such as `Privacy_Camera`.
func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}
