import ApplicationServices
import CocoNotchCore
import CryptoKit
import ImageIO
import SwiftUI

extension NotchWidget {
    static let clipboard = NotchWidget(
        id: "clipboard",
        title: String(localized: "Clipboard"),
        systemImage: "square.on.square",
        makeView: { AnyView(ClipboardView()) },
        makeSettings: { AnyView(ClipboardSettings()) }
    )
}

private let historySizeKey = "clipboard.historySize"
private let capturesImagesKey = "clipboard.capturesImages"
private let pastesIntoAppKey = "clipboard.pastesIntoApp"
private let ignoredBundleIDsKey = "clipboard.ignoredBundleIDs"
private let defaultHistorySize = 50
private let accessibilitySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

private func readSetting<Value>(_ key: String, default defaultValue: Value) -> Value {
    UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue
}

/// A downscaled copy of a saved image for the list and preview, with the full image's size.
final class ClipboardImage {
    let image: NSImage
    let pixelSize: (width: Int, height: Int)?
    let byteCount: Int?

    init(image: NSImage, pixelSize: (width: Int, height: Int)?, byteCount: Int?) {
        self.image = image
        self.pixelSize = pixelSize
        self.byteCount = byteCount
    }
}

/// Big enough for the preview pane at 2x.
nonisolated private let thumbnailPixelSize = 600

nonisolated private func getThumbnailName(_ fileName: String) -> String {
    fileName.replacing(".png", with: ".thumb.png")
}

nonisolated private func makeThumbnail(of source: CGImageSource) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
}

/// Records the clipboard for the whole app, so copies made while the notch is closed are kept too.
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipboardItem] = []
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    // Bounded, since a history of screenshots would otherwise keep every preview in memory.
    @ObservationIgnored private let images = {
        let cache = NSCache<NSString, ClipboardImage>()
        cache.countLimit = 60
        return cache
    }()
    @ObservationIgnored private var lastFrontmostBundleID: String?
    // Writes run in order off the main actor, so a long history never stalls the notch.
    private let writeQueue = DispatchQueue(label: "CocoNotch.clipboard.write", qos: .utility)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let directory = URL.applicationSupportDirectory.appending(path: "CocoNotch/Clipboard")
    private var historyURL: URL { directory.appending(path: "history.json") }

    /// macOS posts no event when the clipboard changes, so this checks its change count, which is cheap to read.
    func start() {
        guard pollTask == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Copies can hold private text, so only this user may read the folder.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? Data(contentsOf: historyURL) {
            if let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
                history = decoded
            } else {
                // Kept aside so the next save doesn't overwrite a history this version can't read.
                let backupURL = directory.appending(path: "history-unreadable.json")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.moveItem(at: historyURL, to: backupURL)
            }
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
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The copy happened up to one poll ago, possibly in the app the user just left, so that app counts too.
        let possibleSources = [lastFrontmostBundleID, sourceBundleID].compactMap(\.self)
        lastFrontmostBundleID = sourceBundleID
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        let kind = getClipboardCaptureKind(
            types: pasteboard.types?.map(\.rawValue) ?? [],
            text: text,
            sourceBundleIDs: possibleSources,
            ignoredBundleIDs: decodeIDSet(readSetting(ignoredBundleIDsKey, default: "")),
            capturesImages: readSetting(capturesImagesKey, default: true)
        )
        switch kind {
        case .text:
            if let text {
                add(ClipboardItem(kind: .text, value: text, copiedAt: .now, sourceBundleID: sourceBundleID))
            }
        case .image:
            let png = pasteboard.data(forType: .png)
            let tiff = png == nil ? pasteboard.data(forType: .tiff) : nil
            let directory = directory
            Task {
                let fileName = await Task.detached { saveImage(png: png, tiff: tiff, in: directory) }.value
                if let fileName {
                    add(ClipboardItem(kind: .image, value: fileName, copiedAt: .now, sourceBundleID: sourceBundleID))
                }
            }
        case nil:
            break
        }
    }

    private func add(_ item: ClipboardItem) {
        save(addClipboardItem(item, to: history, limit: readSetting(historySizeKey, default: defaultHistorySize)))
    }

    private func save(_ newHistory: [ClipboardItem]) {
        for fileName in getUnusedImageFiles(old: history, new: newHistory) {
            images.removeObject(forKey: fileName as NSString)
            for name in [fileName, getThumbnailName(fileName)] {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
        history = newHistory
        let historyURL = historyURL
        writeQueue.async {
            do {
                try JSONEncoder().encode(newHistory).write(to: historyURL, options: .atomic)
            } catch {
                print("CocoNotch couldn't save the clipboard history: \(error)")
            }
        }
    }

    /// The image's thumbnail, saved when it was copied; older items without one get it made from the full image.
    func getImage(for item: ClipboardItem) -> ClipboardImage? {
        if let image = images.object(forKey: item.value as NSString) { return image }
        let url = directory.appending(path: item.value)
        let thumbnailURL = directory.appending(path: getThumbnailName(item.value))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = NSImage(contentsOf: thumbnailURL)
                ?? makeThumbnail(of: source).map({ NSImage(cgImage: $0, size: .zero) })
        else { return nil }
        // Reads only the file's header, not its pixels.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        let loaded = ClipboardImage(
            image: thumbnail,
            pixelSize: width.flatMap { width in height.map { (width, $0) } },
            byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        )
        images.setObject(loaded, forKey: item.value as NSString)
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
            if let image = NSImage(contentsOf: directory.appending(path: item.value)) {
                pasteboard.writeObjects([image])
            }
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

/// Saves the image as PNG under a hash of its data, so copying the same image again finds the same file. Runs off the
/// main actor, since hashing and converting a large screenshot would stall the notch.
nonisolated private func saveImage(png: Data?, tiff: Data?, in directory: URL) -> String? {
    guard let png = png ?? tiff.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
    else { return nil }
    let fileName = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
    let url = directory.appending(path: fileName)
    if !FileManager.default.fileExists(atPath: url.path) {
        guard (try? png.write(to: url)) != nil else { return nil }
        if let source = CGImageSourceCreateWithData(png as CFData, nil), let thumbnail = makeThumbnail(of: source) {
            try? NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: getThumbnailName(fileName)))
        }
    }
    return fileName
}

/// Sends ⌘V to the app the user was in. The notch panel never activates CocoNotch, but a click can make it the key
/// window, so the other app gets keyboard focus back first.
private func pasteIntoFrontmostApp() {
    (NSApp.keyWindow as? NotchPanel)?.returnKeyFocus()
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search clipboard history", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onSubmit { selected.map(store.copy) }
                        .onKeyPress(.downArrow) { select(offset: 1, in: items, from: selected) }
                        .onKeyPress(.upArrow) { select(offset: -1, in: items, from: selected) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Picker("Type", selection: $kind) {
                    Text("All Types").tag(ClipboardItem.Kind?.none)
                    Text("Text").tag(ClipboardItem.Kind?.some(.text))
                    Text("Images").tag(ClipboardItem.Kind?.some(.image))
                }
                .labelsHidden()
                .fixedSize()
            }
            if let selected {
                HStack(alignment: .top, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(items) { item in
                                    ClipboardRow(item: item, isSelected: item.id == selected.id) {
                                        selectedID = item.id
                                    }
                                    .id(item.id)
                                }
                            }
                        }
                        // The system scroller is heavy in a 270pt list; the arrow keys keep the selection in view.
                        .scrollIndicators(.never)
                        .onChange(of: selectedID) { proxy.scrollTo(selectedID) }
                    }
                    .frame(width: 220)
                    .padding(.trailing, 12)
                    Divider()
                    ClipboardDetail(item: selected, pastesIntoApp: pastesIntoApp, isTrusted: isTrusted)
                        .padding(.leading, 16)
                }
                // The notch caps a widget at about 290pt, so the search bar and this split must fit in it.
                .frame(height: 236)
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
        guard let id = getMovedSelection(in: items.map(\.id), from: selected?.id, by: offset) else { return .ignored }
        selectedID = id
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
        .padding(.horizontal, 12)
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
    let isTrusted: Bool
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
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(minHeight: 30, maxHeight: .infinity)
            // Lines the preview's first line up with the first row's title.
            .padding(.top, 6)
            .layoutPriority(-1)
            Divider()
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text("Information")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
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
                        HStack(spacing: 4) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            if row.label == clipboardSourceLabel, let icon = item.sourceBundleID.flatMap(getAppIcon) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 14, height: 14)
                            }
                            Text(row.value)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .font(.caption)
                // The details and the actions always get their full height; the preview takes what is left.
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 12) {
                Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") {
                    store.togglePin(item)
                }
                .help(item.isPinned ? "Unpin" : "Pin so it's never dropped")
                Button("Delete", systemImage: "trash") { store.delete(item) }
                    .help("Delete")
                if pastesIntoApp && !isTrusted {
                    Button("Allow Pasting", systemImage: "exclamationmark.triangle", action: openAccessibilitySettings)
                        .foregroundStyle(.orange)
                        .help(
                            "To paste into the current app, allow CocoNotch in Accessibility. Until then, clicks only copy."
                        )
                }
                Spacer()
                Button {
                    store.copy(item)
                } label: {
                    HStack(spacing: 6) {
                        Text(pastesIntoApp && isTrusted ? "Paste to \(getFrontmostAppName())" : "Copy")
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
            .fixedSize(horizontal: false, vertical: true)
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
            Section {
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
            } header: {
                Text("History")
            } footer: {
                Text(
                    "History is kept on this Mac, unencrypted, in a folder only your account can read, so it survives a restart. Copies from password managers are never saved; add other apps you copy secrets from under Ignored apps."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
    NSWorkspace.shared.frontmostApplication?.localizedName ?? String(localized: "App")
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
