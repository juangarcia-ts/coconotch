import ApplicationServices
import CocoNotchCore
import CryptoKit
import SwiftUI

extension NotchWidget {
    static let clipboard = NotchWidget(
        id: "clipboard",
        title: "Clipboard",
        systemImage: "doc.on.clipboard",
        makeView: { AnyView(ClipboardView()) },
        makeSettings: { AnyView(ClipboardSettings()) },
        makeSummary: { AnyView(ClipboardSummary()) }
    )
}

private let historySizeKey = "clipboard.historySize"
private let capturesImagesKey = "clipboard.capturesImages"
private let pastesIntoAppKey = "clipboard.pastesIntoApp"
private let ignoredBundleIDsKey = "clipboard.ignoredBundleIDs"
private let defaultHistorySize = 50
private let summaryCount = 3
private let accessibilitySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

/// Records the clipboard for the whole app, so copies made while the notch is closed are kept too.
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipboardItem] = []
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let directory = URL.applicationSupportDirectory.appending(path: "CocoNotch/Clipboard")
    private var historyURL: URL { directory.appending(path: "history.json") }

    /// macOS posts no event when the clipboard changes, so this checks its change count, which is cheap to read.
    func start() {
        guard pollTask == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: historyURL) {
            history = (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.capture()
            }
        }
    }

    private func capture() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        let kind = getClipboardCaptureKind(
            types: pasteboard.types?.map(\.rawValue) ?? [],
            text: text,
            sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            ignoredBundleIDs: decodeIDSet(readSetting(ignoredBundleIDsKey, default: "")),
            capturesImages: readSetting(capturesImagesKey, default: true)
        )
        switch kind {
        case .text:
            if let text { add(ClipboardItem(kind: .text, value: text)) }
        case .image:
            if let fileName = saveImage(from: pasteboard) { add(ClipboardItem(kind: .image, value: fileName)) }
        case nil:
            break
        }
    }

    /// Saves the image as PNG under a hash of its data, so copying the same image again finds the same file.
    private func saveImage(from pasteboard: NSPasteboard) -> String? {
        guard
            let png = pasteboard.data(forType: .png)
                ?? pasteboard.data(forType: .tiff).flatMap({
                    NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
                })
        else { return nil }
        let fileName = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = directory.appending(path: fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? png.write(to: url)) != nil else { return nil }
        }
        return fileName
    }

    private func add(_ item: ClipboardItem) {
        save(addClipboardItem(item, to: history, limit: readSetting(historySizeKey, default: defaultHistorySize)))
    }

    private func save(_ newHistory: [ClipboardItem]) {
        for fileName in getUnusedImageFiles(old: history, new: newHistory) {
            thumbnails[fileName] = nil
            try? FileManager.default.removeItem(at: directory.appending(path: fileName))
        }
        history = newHistory
        if let data = try? JSONEncoder().encode(newHistory) { try? data.write(to: historyURL) }
    }

    func getImage(for item: ClipboardItem) -> NSImage? {
        if let image = thumbnails[item.value] { return image }
        let image = NSImage(contentsOf: directory.appending(path: item.value))
        thumbnails[item.value] = image
        return image
    }

    /// Puts the item back on the clipboard and on top of the history, then pastes it if the user turned that on.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.value, forType: .string)
        case .image:
            if let image = getImage(for: item) { pasteboard.writeObjects([image]) }
        }
        lastChangeCount = pasteboard.changeCount
        add(item)
        if readSetting(pastesIntoAppKey, default: false), AXIsProcessTrusted() { pasteIntoFrontmostApp() }
    }

    func togglePin(_ item: ClipboardItem) {
        save(
            history.map {
                $0.id == item.id ? ClipboardItem(id: $0.id, kind: $0.kind, value: $0.value, isPinned: !$0.isPinned) : $0
            })
    }

    func delete(_ item: ClipboardItem) {
        save(history.filter { $0.id != item.id })
    }

    func clearUnpinned() {
        save(history.filter(\.isPinned))
    }

    func applyHistorySize() {
        save(trimClipboardHistory(history, limit: readSetting(historySizeKey, default: defaultHistorySize)))
    }
}

/// Sends ⌘V to the app the user was in. The notch panel never activates CocoNotch, but a click can make it the key
/// window, so the other app gets keyboard focus back first.
private func pasteIntoFrontmostApp() {
    NSWorkspace.shared.frontmostApplication?.activate()
    Task {
        try? await Task.sleep(for: .milliseconds(100))
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

private func openAccessibilitySettings() {
    // Prompting also adds CocoNotch to the Accessibility list, so the user only has to switch it on.
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if let accessibilitySettingsURL { NSWorkspace.shared.open(accessibilitySettingsURL) }
}

private struct ClipboardView: View {
    @AppStorage(pastesIntoAppKey) private var pastesIntoApp = false
    @State private var query = ""
    @State private var isTrusted = AXIsProcessTrusted()
    private let store = ClipboardStore.shared

    var body: some View {
        let items = getVisibleClipboardItems(store.history, query: query)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Clear", systemImage: "trash") { store.clearUnpinned() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear the history, keeping pinned items")
                    .disabled(store.history.allSatisfy(\.isPinned))
            }
            if pastesIntoApp && !isTrusted {
                HStack {
                    Text(
                        "To paste into the current app, allow CocoNotch in Accessibility. Until then, clicks only copy."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Open Settings", action: openAccessibilitySettings)
                        .controlSize(.small)
                }
            }
            if items.isEmpty {
                Text(query.isEmpty ? "Copy some text or an image and it shows up here." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { ClipboardRow(item: $0) }
                    }
                }
                .frame(height: 220)
            }
        }
        .onAppear { isTrusted = AXIsProcessTrusted() }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    @State private var isHovering = false
    private let store = ClipboardStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.copy(item)
            } label: {
                HStack(spacing: 10) {
                    ClipboardItemContent(item: item, lineLimit: 2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            if isHovering || item.isPinned {
                Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.fill" : "pin") {
                    store.togglePin(item)
                }
                .help(item.isPinned ? "Unpin" : "Pin so it's never dropped")
            }
            if isHovering {
                Button("Delete", systemImage: "xmark") { store.delete(item) }
                    .help("Delete")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }
}

private struct ClipboardItemContent: View {
    let item: ClipboardItem
    let lineLimit: Int

    var body: some View {
        switch item.kind {
        case .text:
            Text(formatClipboardPreview(item.value))
                .lineLimit(lineLimit)
                .font(.callout)
        case .image:
            if let image = ClipboardStore.shared.getImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 120, maxHeight: lineLimit == 1 ? 18 : 48, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Label("Image", systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The latest copies, for the Home tab; clicking one copies it again.
private struct ClipboardSummary: View {
    private let store = ClipboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(store.history.prefix(summaryCount)) { item in
                Button {
                    store.copy(item)
                } label: {
                    ClipboardItemContent(item: item, lineLimit: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            if store.history.isEmpty {
                Text("Nothing copied yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClipboardSettings: View {
    @AppStorage(historySizeKey) private var historySize = defaultHistorySize
    @AppStorage(capturesImagesKey) private var capturesImages = true
    @AppStorage(pastesIntoAppKey) private var pastesIntoApp = false
    @AppStorage(ignoredBundleIDsKey) private var storedIgnoredIDs = ""
    @State private var isConfirmingClear = false
    private let store = ClipboardStore.shared

    var body: some View {
        Form {
            Section("History") {
                Picker("Keep", selection: $historySize) {
                    ForEach([10, 25, 50, 100, 200, 500], id: \.self) { Text("\($0) items").tag($0) }
                }
                Toggle("Save copied images", isOn: $capturesImages)
                Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                    .confirmationDialog("Clear the clipboard history?", isPresented: $isConfirmingClear) {
                        Button("Clear History", role: .destructive) { store.clearUnpinned() }
                    } message: {
                        Text("Pinned items are kept.")
                    }
            }
            Section {
                Toggle("Paste into the current app when I click an item", isOn: $pastesIntoApp)
                if pastesIntoApp {
                    // Access can change in System Settings at any time, so the status re-checks while shown.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if AXIsProcessTrusted() {
                            Label("Accessibility access is on.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Pasting sends ⌘V to the app you're in, which needs Accessibility access.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Open Accessibility Settings", action: openAccessibilitySettings)
                            }
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Paste")
            } footer: {
                Text("Clicking an item always copies it back to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(decodeIDSet(storedIgnoredIDs).sorted(), id: \.self) { id in
                    HStack {
                        Text(getAppName(bundleID: id))
                        Text(id).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { updateIgnored { $0.remove(id) } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add App") {
                    ForEach(listRunningApps(excluding: decodeIDSet(storedIgnoredIDs)), id: \.self) { id in
                        Button(getAppName(bundleID: id)) { updateIgnored { $0.insert(id) } }
                    }
                }
                .fixedSize()
            } header: {
                Text("Ignored apps")
            } footer: {
                Text(
                    "Copies made in these apps aren't saved. Password managers that mark their copies are always skipped."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: historySize) { store.applyHistorySize() }
    }

    private func updateIgnored(_ change: (inout Set<String>) -> Void) {
        var ids = decodeIDSet(storedIgnoredIDs)
        change(&ids)
        storedIgnoredIDs = encodeIDSet(ids)
    }
}

private func getAppName(bundleID: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        .map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") } ?? bundleID
}

private func listRunningApps(excluding ignoredIDs: Set<String>) -> [String] {
    Set(
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
    )
    .subtracting(ignoredIDs)
    .sorted { getAppName(bundleID: $0).localizedStandardCompare(getAppName(bundleID: $1)) == .orderedAscending }
}
