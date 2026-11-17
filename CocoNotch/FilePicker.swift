import SwiftUI
import UniformTypeIdentifiers

/// The open panel for widgets. The notch that opened it stays open behind it, since moving over to the panel would
/// otherwise close it.
@Observable
final class FilePicker {
    static let shared = FilePicker()

    /// The notch the open panel was opened from, which stays open behind it; nil while no panel shows.
    private(set) var openerID: ObjectIdentifier?

    /// The files the user picks, or none when they cancel. An empty `types` allows any file.
    func chooseFiles(types: [UTType] = [], allowsFolders: Bool = false) async -> [URL] {
        guard openerID == nil else { return [] }
        // The button was just clicked, so the notch that asked is the one under the pointer.
        let opener = NSApp.windows.first { $0 is NotchPanel && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        openerID = opener.map(ObjectIdentifier.init)
        defer { openerID = nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = allowsFolders
        if !types.isEmpty { panel.allowedContentTypes = types }
        // The notch steps down to a normal window so the panel can sit over it; raising the panel instead leaves its
        // file browser, drawn by another process, unable to take clicks.
        opener?.level = .normal
        defer { opener?.level = NotchPanel.windowLevel }
        // The notch never activates CocoNotch, and the panel only takes the keyboard when it is active.
        NSApp.activate()
        return await panel.begin() == .OK ? panel.urls : []
    }
}

/// The pill-shaped button widgets use to open the file picker.
struct ChooseFilesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Choose Files…", systemImage: "folder")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
