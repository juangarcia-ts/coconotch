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

struct ClipboardImage {
    let image: NSImage
    let pixelSize: (width: Int, height: Int)?
    let byteCount: Int?
}

/// Records the clipboard for the whole app, so copies made while the notch is closed are kept too.
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipboardItem] = []
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var images: [String: ClipboardImage] = [:]
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
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let kind = getClipboardCaptureKind(
            types: pasteboard.types?.map(\.rawValue) ?? [],
            text: text,
            sourceBundleID: sourceBundleID,
            ignoredBundleIDs: decodeIDSet(readSetting(ignoredBundleIDsKey, default: "")),
            capturesImages: readSetting(capturesImagesKey, default: true)
        )
        switch kind {
        case .text:
            if let text {
                add(ClipboardItem(kind: .text, value: text, copiedAt: .now, sourceBundleID: sourceBundleID))
            }
        case .image:
            if let fileName = saveImage(from: pasteboard) {
                add(ClipboardItem(kind: .image, value: fileName, copiedAt: .now, sourceBundleID: sourceBundleID))
            }
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
            images[fileName] = nil
            try? FileManager.default.removeItem(at: directory.appending(path: fileName))
        }
        history = newHistory
        if let data = try? JSONEncoder().encode(newHistory) { try? data.write(to: historyURL) }
    }

    func getImage(for item: ClipboardItem) -> ClipboardImage? {
        if let image = images[item.value] { return image }
        let url = directory.appending(path: item.value)
        guard let image = NSImage(contentsOf: url) else { return nil }
        let rep = image.representations.first
        let loaded = ClipboardImage(
            image: image,
            pixelSize: rep.map { ($0.pixelsWide, $0.pixelsHigh) },
            byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        )
        images[item.value] = loaded
        return loaded
    }

    /// Puts the item back on the clipboard and on top of the history, then pastes it if the user turned that on.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.value, forType: .string)
        case .image:
            if let image = getImage(for: item) { pasteboard.writeObjects([image.image]) }
        }
        lastChangeCount = pasteboard.changeCount
        var item = item
        item.copiedAt = .now
        add(item)
        if readSetting(pastesIntoAppKey, default: false), AXIsProcessTrusted() { pasteIntoFrontmostApp() }
    }

    func togglePin(_ item: ClipboardItem) {
        save(
            history.map {
                var toggled = $0
                if $0.id == item.id { toggled.isPinned.toggle() }
                return toggled
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
    @State private var kind: ClipboardItem.Kind?
    @State private var selectedID: UUID?
    @State private var isTrusted = AXIsProcessTrusted()
    @FocusState private var isSearchFocused: Bool
    private let store = ClipboardStore.shared

    var body: some View {
        let items = getVisibleClipboardItems(store.history, query: query, kind: kind)
        let selected = items.first { $0.id == selectedID } ?? items.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Type to filter entries…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { selected.map(store.copy) }
                    .onKeyPress(.downArrow) { select(offset: 1, in: items, from: selected) }
                    .onKeyPress(.upArrow) { select(offset: -1, in: items, from: selected) }
                Picker("Type", selection: $kind) {
                    Text("All Types").tag(ClipboardItem.Kind?.none)
                    Text("Text").tag(ClipboardItem.Kind?.some(.text))
                    Text("Images").tag(ClipboardItem.Kind?.some(.image))
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
            if let selected {
                HStack(alignment: .top, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(items) { item in
                                    ClipboardRow(item: item, isSelected: item.id == selected.id) {
                                        selectedID = item.id
                                    }
                                    .id(item.id)
                                }
                            }
                            .padding(.trailing, 6)
                        }
                        .onChange(of: selectedID) { proxy.scrollTo(selectedID) }
                    }
                    .frame(width: 230)
                    Divider()
                    ClipboardDetail(item: selected, pastesIntoApp: pastesIntoApp && isTrusted)
                        .padding(.leading, 12)
                }
                .frame(height: 250)
            } else {
                Text(store.history.isEmpty ? "Copy some text or an image and it shows up here." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .onAppear {
            isTrusted = AXIsProcessTrusted()
            isSearchFocused = true
        }
    }

    private func select(offset: Int, in items: [ClipboardItem], from selected: ClipboardItem?) -> KeyPress.Result {
        guard let index = items.firstIndex(where: { $0.id == selected?.id }) else { return .ignored }
        selectedID = items[max(0, min(items.count - 1, index + offset))].id
        return .handled
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let select: () -> Void
    private let store = ClipboardStore.shared

    var body: some View {
        let image = item.kind == .image ? store.getImage(for: item) : nil
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .image ? "photo" : "doc.text")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(getClipboardItemTitle(item, pixelSize: image?.pixelSize))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isSelected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // Hovering picks the row, like moving through Raycast's list with the arrow keys.
        .onHover { if $0 { select() } }
        .onTapGesture { store.copy(item) }
        .contextMenu {
            Button("Copy") { store.copy(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button("Delete", role: .destructive) { store.delete(item) }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// The selected item's full preview and details, with its actions.
private struct ClipboardDetail: View {
    let item: ClipboardItem
    let pastesIntoApp: Bool
    private let store = ClipboardStore.shared

    var body: some View {
        let image = item.kind == .image ? store.getImage(for: item) : nil
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        Text(item.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 100)
            Divider()
            TimelineView(.everyMinute) { context in
                Grid(alignment: .leading, verticalSpacing: 4) {
                    ForEach(
                        makeClipboardDetails(
                            item,
                            sourceName: item.sourceBundleID.map { getAppName(bundleID: $0) },
                            pixelSize: image?.pixelSize,
                            byteCount: image?.byteCount,
                            now: context.date
                        ),
                        id: \.label
                    ) { row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                if row.label == "Source", let icon = item.sourceBundleID.flatMap(getAppIcon) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 14, height: 14)
                                }
                                Text(row.value)
                                    .lineLimit(1)
                            }
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") {
                    store.togglePin(item)
                }
                .help(item.isPinned ? "Unpin" : "Pin so it's never dropped")
                Button("Delete", systemImage: "trash") { store.delete(item) }
                    .help("Delete")
                Spacer()
                Button {
                    store.copy(item)
                } label: {
                    HStack(spacing: 6) {
                        Text(pastesIntoApp ? "Paste to \(getFrontmostAppName())" : "Copy")
                        Image(systemName: "return")
                            .font(.caption2.weight(.semibold))
                            .padding(3)
                            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }
}

/// The latest copies, for the Home tab; clicking one copies it again.
private struct ClipboardSummary: View {
    private let store = ClipboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(store.history.prefix(summaryCount)) { item in
                let image = item.kind == .image ? store.getImage(for: item) : nil
                Button {
                    store.copy(item)
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if let image {
                                Image(nsImage: image.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 14, height: 14)
                        Text(getClipboardItemTitle(item, pixelSize: image?.pixelSize))
                            .font(.callout)
                            .lineLimit(1)
                    }
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

private func getAppIcon(bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
        NSWorkspace.shared.icon(forFile: $0.path)
    }
}

private func getFrontmostAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"
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
