import CocoNotchCore
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

extension NotchWidget {
    static let shelf = NotchWidget(
        id: "shelf",
        title: "Shelf",
        systemImage: "tray",
        makeView: { AnyView(ShelfView()) },
        makeSettings: { AnyView(ShelfSettings()) }
    )
}

let shelfOpensOnDragHoverKey = "shelf.opensOnDragHover"
private let copiesFilesKey = "shelf.copiesFiles"
private let removesAfterDragOutKey = "shelf.removesAfterDragOut"

private func readSetting(_ key: String, default defaultValue: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
}

/// Holds the shelf for the whole app, so a drop on the closed notch lands even before the widget is shown.
@Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var items: [ShelfItem] = []
    /// Files whose bookmark can't be resolved right now, for example on an unplugged drive.
    private(set) var missingIDs: Set<UUID> = []
    var selection: Set<UUID> = []
    @ObservationIgnored var selectionAnchor: UUID?
    /// Whether a drag is over the notch, so the shelf can show where it will land.
    var isDropTargeted = false
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored private let preview = ShelfPreview()
    private let writeQueue = DispatchQueue(label: "CocoNotch.shelf.write", qos: .utility)
    private let directory = URL.applicationSupportDirectory.appending(path: "CocoNotch/Shelf")
    private var itemsURL: URL { directory.appending(path: "items.json") }
    private var copiesDirectory: URL { directory.appending(path: "Copies") }

    func start() {
        try? FileManager.default.createDirectory(at: copiesDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: itemsURL),
            let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data)
        {
            items = decoded
        }
        refresh()
    }

    /// Follows every file to where it is now and drops the ones that went to the Trash.
    func refresh() {
        var missing = Set<UUID>()
        var isChanged = false
        var updated: [ShelfItem] = []
        for var item in items {
            guard item.kind == .file else {
                updated.append(item)
                continue
            }
            var isStale = false
            let url = item.bookmark.flatMap {
                try? URL(
                    resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
            }
            switch getShelfFileStatus(
                savedPath: item.value, resolvedPath: url?.path(percentEncoded: false), isStale: isStale)
            {
            case .available:
                updated.append(item)
            case .refresh(let path):
                item.value = path
                item.bookmark = (try? url?.bookmarkData()) ?? item.bookmark
                updated.append(item)
                isChanged = true
            case .trashed:
                isChanged = true
            case .missing:
                missing.insert(item.id)
                updated.append(item)
            }
        }
        missingIDs = missing
        if isChanged { save(updated) }
    }

    func add(_ providers: [NSItemProvider]) {
        let copiesFiles = readSetting(copiesFilesKey, default: false)
        Task {
            var newItems: [ShelfItem] = []
            for provider in providers {
                if let item = await loadItem(from: provider, copiesFiles: copiesFiles) { newItems.append(item) }
            }
            save(addShelfItems(newItems, to: items))
        }
    }

    private func loadItem(from provider: NSItemProvider, copiesFiles: Bool) async -> ShelfItem? {
        let copiesDirectory = copiesDirectory
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard
                let url = await withCheckedContinuation({ continuation in
                    loadURL(from: provider) { continuation.resume(returning: $0) }
                })
            else {
                return nil
            }
            guard copiesFiles else { return makeFileItem(url, isCopy: false) }
            let copy = await Task.detached { copyFile(url, into: copiesDirectory) }.value
            return copy.map { makeFileItem($0, isCopy: true) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = await withCheckedContinuation { continuation in
                loadURL(from: provider) { continuation.resume(returning: $0) }
            }
            return url.map { ShelfItem(kind: .link, value: $0.absoluteString) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text = await withCheckedContinuation { continuation in
                loadText(from: provider) { continuation.resume(returning: $0) }
            }
            return text.map { ShelfItem(kind: .text, value: $0) }
        }
        // Images from a browser and attachments from Mail come as data or a promised file, so they're always copied.
        guard
            let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .data) == true
            })
        else { return nil }
        let copy = await withCheckedContinuation {
            continuation in
            copyFileRepresentation(from: provider, type: type, into: copiesDirectory) {
                continuation.resume(returning: $0)
            }
        }
        return copy.map { makeFileItem($0, isCopy: true) }
    }

    private func makeFileItem(_ url: URL, isCopy: Bool) -> ShelfItem {
        ShelfItem(
            kind: .file,
            value: url.path(percentEncoded: false),
            bookmark: try? url.bookmarkData(),
            isCopy: isCopy,
            byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        )
    }

    func remove(_ ids: Set<UUID>) {
        selection.subtract(ids)
        save(items.filter { !ids.contains($0.id) })
    }

    func clear() {
        selection = []
        save([])
    }

    private func save(_ newItems: [ShelfItem]) {
        for path in getUnusedShelfCopies(old: items, new: newItems) {
            // Only folders the shelf made, in case a copy was moved out of it since.
            let folder = URL(filePath: path).deletingLastPathComponent()
            if folder.deletingLastPathComponent().standardizedFileURL == copiesDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        items = newItems
        let itemsURL = itemsURL
        writeQueue.async {
            do {
                try JSONEncoder().encode(newItems).write(to: itemsURL, options: .atomic)
            } catch {
                print("CocoNotch couldn't save the shelf: \(error)")
            }
        }
    }

    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let result = selectShelfItems(
            clicked: id, in: items.map(\.id), selection: selection, anchor: selectionAnchor,
            isToggling: modifiers.contains(.command), isExtending: modifiers.contains(.shift))
        selection = result.selection
        selectionAnchor = result.anchor
    }

    func getItems(_ ids: some Collection<UUID>) -> [ShelfItem] {
        items.filter { ids.contains($0.id) }
    }

    func getURL(for item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: URL(filePath: item.value)
        case .link: URL(string: item.value)
        case .text: nil
        }
    }

    func getIcon(for item: ShelfItem) -> NSImage {
        switch item.kind {
        case .file:
            return thumbnails.object(forKey: item.value as NSString) ?? NSWorkspace.shared.icon(forFile: item.value)
        case .text:
            return NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "Text") ?? NSImage()
        case .link:
            return NSImage(systemSymbolName: "link", accessibilityDescription: "Link") ?? NSImage()
        }
    }

    func loadThumbnail(for item: ShelfItem) async {
        guard item.kind == .file, thumbnails.object(forKey: item.value as NSString) == nil else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(filePath: item.value), size: CGSize(width: 48, height: 48), scale: 2,
            representationTypes: .thumbnail)
        if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnails.setObject(thumbnail.nsImage, forKey: item.value as NSString)
        }
    }

    /// What a drag or Copy puts on the pasteboard for each item.
    func getPasteboardWriters(_ items: [ShelfItem]) -> [NSPasteboardWriting] {
        items.compactMap { item in
            item.kind == .text ? item.value as NSString : getURL(for: item).map { $0 as NSURL }
        }
    }

    func open(_ items: [ShelfItem]) {
        for url in items.compactMap(getURL) { NSWorkspace.shared.open(url) }
    }

    func showQuickLook(_ items: [ShelfItem]) {
        preview.urls = items.compactMap(getURL).filter(\.isFileURL)
        guard !preview.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        // The notch never activates CocoNotch, and Quick Look only shows over other apps when it is active.
        NSApp.activate()
        panel.dataSource = preview
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func revealInFinder(_ items: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.compactMap(getURL).filter(\.isFileURL))
    }

    func sendWithAirDrop(_ items: [ShelfItem]) {
        NSApp.activate()
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: getShareItems(items))
    }

    func getShareItems(_ items: [ShelfItem]) -> [Any] {
        items.map { item -> Any in
            if let url = getURL(for: item) { return url }
            return item.value
        }
    }

    func copyToPasteboard(_ items: [ShelfItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(getPasteboardWriters(items))
    }
}

/// Quick Look reads the files from here; it's kept by the store so the preview outlives the notch closing.
private final class ShelfPreview: NSObject, @MainActor QLPreviewPanelDataSource {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

// The item provider calls back on a background queue, so these build their callbacks outside the main actor.
nonisolated private func loadURL(from provider: NSItemProvider, completion: @escaping @Sendable (URL?) -> Void) {
    _ = provider.loadObject(ofClass: URL.self) { url, _ in completion(url) }
}

nonisolated private func loadText(from provider: NSItemProvider, completion: @escaping @Sendable (String?) -> Void) {
    _ = provider.loadObject(ofClass: String.self) { text, _ in completion(text) }
}

/// The provider deletes its file once the callback returns, so it's copied inside it.
nonisolated private func copyFileRepresentation(
    from provider: NSItemProvider, type: String, into directory: URL,
    completion: @escaping @Sendable (URL?) -> Void
) {
    let name = provider.suggestedName
    _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        completion(url.flatMap { copyFile($0, into: directory, name: name) })
    }
}

/// Copies into a folder of its own, so the copy keeps the original's name.
nonisolated private func copyFile(_ url: URL, into directory: URL, name: String? = nil) -> URL? {
    let folder = directory.appending(path: UUID().uuidString)
    var fileName = name ?? url.lastPathComponent
    if (fileName as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
        fileName += "." + url.pathExtension
    }
    let destination = folder.appending(path: fileName)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    } catch {
        print("CocoNotch couldn't copy \(url.lastPathComponent) to the shelf: \(error)")
        return nil
    }
}

/// Takes drops anywhere on the notch, open or closed. Tabs and Home cards being reordered are left to their own drop.
struct ShelfDropDelegate: DropDelegate {
    let isEnabled: Bool
    let onTargetChange: (_ isTargeted: Bool, _ didDrop: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && !info.hasItemsConforming(to: [widgetDragType])
    }

    func dropEntered(info: DropInfo) {
        ShelfStore.shared.isDropTargeted = true
        onTargetChange(true, false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        ShelfStore.shared.isDropTargeted = false
        onTargetChange(false, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        ShelfStore.shared.isDropTargeted = false
        ShelfStore.shared.add(info.itemProviders(for: [.item]))
        onTargetChange(false, true)
        return true
    }
}

private struct ShelfView: View {
    @State private var isConfirmingClear = false
    private let store = ShelfStore.shared

    var body: some View {
        let ids = getShelfSelectedOrAll(store.items.map(\.id), selection: store.selection)
        let targets = store.getItems(ids)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(formatShelfSummary(store.items))
                    .foregroundStyle(.secondary)
                if !store.selection.isEmpty {
                    Text("\(store.selection.count) selected")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !store.items.isEmpty {
                    Button("Quick Look", systemImage: "eye") { store.showQuickLook(targets) }
                        .help("Quick Look")
                    Button("AirDrop", systemImage: "airplayaudio") { store.sendWithAirDrop(targets) }
                        .help("Send with AirDrop")
                    ShareLink(items: targets.compactMap(store.getURL)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share")
                    Button("Clear Shelf", systemImage: "xmark.circle") { isConfirmingClear = true }
                        .help("Clear the shelf")
                        .confirmationDialog("Clear the shelf?", isPresented: $isConfirmingClear) {
                            Button("Clear Shelf", role: .destructive) { store.clear() }
                        } message: {
                            Text("Original files stay where they are; copies the shelf saved are deleted.")
                        }
                }
            }
            .font(.callout)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.title2)
                        Text("Drop files, links or text on the notch to keep them here.")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 6) {
                            ForEach(store.items) { item in
                                ShelfTile(
                                    item: item, isSelected: store.selection.contains(item.id),
                                    isMissing: store.missingIDs.contains(item.id))
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(height: 110)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(store.isDropTargeted ? 0.1 : 0.04))
                    .strokeBorder(
                        Color.primary.opacity(store.isDropTargeted ? 0.4 : 0.12),
                        style: StrokeStyle(lineWidth: 1, dash: store.items.isEmpty ? [5] : []))
            }
            // A click between tiles clears the selection, like Finder.
            .onTapGesture { store.selection = [] }
        }
        .onAppear { store.refresh() }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let isSelected: Bool
    let isMissing: Bool
    private let store = ShelfStore.shared
    @State private var thumbnailVersion = 0

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: store.getIcon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .id(thumbnailVersion)
            Text(getShelfItemTitle(item))
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(6)
        .frame(width: 84, height: 98)
        .background(Color.primary.opacity(isSelected ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isMissing ? 0.4 : 1)
        .overlay { ShelfDragSource(item: item) }
        .help(isMissing ? "\(item.value) can't be found right now." : item.value)
        .task(id: item.value) {
            await store.loadThumbnail(for: item)
            thumbnailVersion += 1
        }
    }
}

/// An AppKit view over each tile, since SwiftUI can't drag several items at once or report where a drag ended.
private struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem

    func makeNSView(context: Context) -> ShelfDragSourceView {
        ShelfDragSourceView()
    }

    func updateNSView(_ nsView: ShelfDragSourceView, context: Context) {
        nsView.item = item
    }
}

private final class ShelfDragSourceView: NSView, NSDraggingSource {
    var item: ShelfItem?
    private var mouseDownEvent: NSEvent?
    private var draggedIDs: Set<UUID> = []
    private let store = ShelfStore.shared

    // The notch panel is rarely key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        mouseDownEvent = event
        if event.clickCount == 2 {
            store.open(store.getItems(getShelfTargets(clicked: item.id, selection: store.selection)))
        } else if !store.selection.contains(item.id) || !event.modifierFlags.isDisjoint(with: [.command, .shift]) {
            // A plain click on a selected item keeps the selection, so the whole selection can be dragged.
            store.select(item.id, modifiers: event.modifierFlags)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click that didn't drag narrows the selection down to this item.
        if let item, mouseDownEvent != nil, event.clickCount == 1,
            event.modifierFlags.isDisjoint(with: [.command, .shift])
        {
            store.select(item.id, modifiers: [])
        }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, let mouseDownEvent,
            hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y) > 3
        else { return }
        self.mouseDownEvent = nil
        draggedIDs = getShelfTargets(clicked: item.id, selection: store.selection)
        let items = store.getItems(draggedIDs)
        let draggingItems = zip(items, store.getPasteboardWriters(items)).enumerated().map { index, pair in
            let draggingItem = NSDraggingItem(pasteboardWriter: pair.1)
            // Fanned out a little, so a multi-item drag shows it carries several.
            let offset = CGFloat(index) * 6
            draggingItem.setDraggingFrame(
                NSRect(x: bounds.midX - 24 + offset, y: bounds.midY - 24 - offset, width: 48, height: 48),
                contents: store.getIcon(for: pair.0))
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let item else { return }
        if !store.selection.contains(item.id) { store.select(item.id, modifiers: []) }
        let items = store.getItems(getShelfTargets(clicked: item.id, selection: store.selection))
        NSMenu.popUpContextMenu(makeMenu(for: items), with: event, for: self)
    }

    private func makeMenu(for items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hasFiles = items.contains { $0.kind == .file }
        menu.items = [
            makeMenuItem("Open", isEnabled: items.contains { $0.kind != .text }) { [store] in store.open(items) },
            makeMenuItem("Quick Look", isEnabled: hasFiles) { [store] in store.showQuickLook(items) },
            makeMenuItem("Show in Finder", isEnabled: hasFiles) { [store] in store.revealInFinder(items) },
            .separator(),
            makeMenuItem("Copy") { [store] in store.copyToPasteboard(items) },
            makeMenuItem("AirDrop") { [store] in store.sendWithAirDrop(items) },
            NSSharingServicePicker(items: store.getShareItems(items)).standardShareMenuItem,
            .separator(),
            makeMenuItem(items.count == 1 ? "Remove" : "Remove \(items.count) Items") { [store] in
                store.remove(Set(items.map(\.id)))
            },
        ]
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        // Always a copy, so the original never moves; and never back onto the notch, where it would be added again.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty, readSetting(removesAfterDragOutKey, default: false) { store.remove(draggedIDs) }
        draggedIDs = []
    }
}

private final class MenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}

private func makeMenuItem(_ title: String, isEnabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    // A menu item holds its target weakly, so it keeps the action alive here.
    item.representedObject = action
    item.isEnabled = isEnabled
    return item
}

private struct ShelfSettings: View {
    @AppStorage(shelfOpensOnDragHoverKey) private var opensOnDragHover = true
    @AppStorage(copiesFilesKey) private var copiesFiles = false
    @AppStorage(removesAfterDragOutKey) private var removesAfterDragOut = false
    @State private var isConfirmingClear = false
    private let store = ShelfStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open the notch when a drag is over it", isOn: $opensOnDragHover)
            } header: {
                Text("Dropping")
            } footer: {
                Text("Drops land on the shelf whether the notch is open or closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep a copy of dropped files", isOn: $copiesFiles)
                Toggle("Remove items after dragging them out", isOn: $removesAfterDragOut)
                Button("Clear Shelf…", role: .destructive) { isConfirmingClear = true }
                    .disabled(store.items.isEmpty)
                    .confirmationDialog("Clear the shelf?", isPresented: $isConfirmingClear) {
                        Button("Clear Shelf", role: .destructive) { store.clear() }
                    } message: {
                        Text("Original files stay where they are; copies the shelf saved are deleted.")
                    }
            } header: {
                Text("Items")
            } footer: {
                Text(
                    "Without a copy, the shelf points at the original and follows it when it moves; a file moved to the Trash leaves the shelf. With a copy, the shelf keeps its own, so the original can go. Dragging out always copies. Images and attachments from apps that don't hand over a file are always copied."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
