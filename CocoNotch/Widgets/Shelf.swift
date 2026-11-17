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
private let defaultShelfKey = "shelf.defaultShelfID"
private let notchDropTargetID = "notch"

private func readSetting(_ key: String, default defaultValue: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
}

/// Holds the shelves for the whole app, so a drop on the closed notch lands even before the widget is shown.
@Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var shelves: [Shelf] = []
    /// Files whose bookmark can't be resolved right now, for example on an unplugged drive.
    private(set) var missingIDs: Set<UUID> = []
    var selection: Set<UUID> = []
    @ObservationIgnored var selectionAnchor: UUID?
    /// What a drag is over: shelves by ID and the notch itself, so the notch opens and the shelf lights up.
    var dropTargetIDs: Set<String> = []
    /// Items being dragged out of a shelf; dropped on another shelf, they move there.
    @ObservationIgnored var draggedIDs: Set<UUID> = []
    @ObservationIgnored var didDrop = false
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored private let preview = ShelfPreview()
    private let writeQueue = DispatchQueue(label: "CocoNotch.shelf.write", qos: .utility)
    private let directory = URL.applicationSupportDirectory.appending(path: "CocoNotch/Shelf")
    private var shelvesURL: URL { directory.appending(path: "shelves.json") }
    private var copiesDirectory: URL { directory.appending(path: "Copies") }

    var items: [ShelfItem] { shelves.flatMap(\.items) }

    /// Where drops on the closed notch go: the shelf picked in Settings, or the first one.
    var defaultShelfID: UUID? {
        let stored = UserDefaults.standard.string(forKey: defaultShelfKey).flatMap(UUID.init(uuidString:))
        return shelves.first { $0.id == stored }?.id ?? shelves.first?.id
    }

    func start() {
        try? FileManager.default.createDirectory(at: copiesDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: shelvesURL),
            let decoded = try? JSONDecoder().decode([Shelf].self, from: data)
        {
            shelves = decoded
        }
        if shelves.isEmpty { save([Shelf(name: makeShelfName(existing: []))]) }
        refresh()
    }

    /// Follows every file to where it is now and drops the ones that went to the Trash.
    func refresh() {
        var missing = Set<UUID>()
        var isChanged = false
        let updated = shelves.map { shelf in
            var shelf = shelf
            shelf.items = shelf.items.compactMap { item in
                guard item.kind == .file else { return item }
                var item = item
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
                    return item
                case .refresh(let path):
                    item.value = path
                    item.bookmark = (try? url?.bookmarkData()) ?? item.bookmark
                    isChanged = true
                    return item
                case .trashed:
                    isChanged = true
                    return nil
                case .missing:
                    missing.insert(item.id)
                    return item
                }
            }
            return shelf
        }
        missingIDs = missing
        if isChanged { save(updated) }
    }

    /// Adds the drop to the shelf, or to the default shelf when none is given.
    func add(_ providers: [NSItemProvider], to shelfID: UUID?) {
        guard let shelfID = shelfID ?? defaultShelfID else { return }
        let copiesFiles = readSetting(copiesFilesKey, default: false)
        Task {
            var newItems: [ShelfItem] = []
            for provider in providers {
                if let item = await loadItem(from: provider, copiesFiles: copiesFiles) { newItems.append(item) }
            }
            updateShelf(shelfID) { $0.items = addShelfItems(newItems, to: $0.items) }
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
            return await loadFileItem(url, copiesFiles: copiesFiles)
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

    private func loadFileItem(_ url: URL, copiesFiles: Bool) async -> ShelfItem? {
        guard copiesFiles else { return makeFileItem(url, isCopy: false) }
        let copiesDirectory = copiesDirectory
        let copy = await Task.detached { copyFile(url, into: copiesDirectory) }.value
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
        save(
            shelves.map { shelf in
                var shelf = shelf
                shelf.items.removeAll { ids.contains($0.id) }
                return shelf
            })
    }

    func clear(_ shelfID: UUID) {
        updateShelf(shelfID) { $0.items = [] }
    }

    func addShelf() -> UUID {
        let shelf = Shelf(name: makeShelfName(existing: shelves))
        save(shelves + [shelf])
        return shelf.id
    }

    func rename(_ shelfID: UUID, to name: String) {
        updateShelf(shelfID) { $0.name = name }
    }

    func deleteShelf(_ shelfID: UUID) {
        guard shelves.count > 1 else { return }
        save(shelves.filter { $0.id != shelfID })
    }

    func move(_ ids: Set<UUID>, to shelfID: UUID) {
        save(moveShelfItems(ids, to: shelfID, in: shelves))
    }

    private func updateShelf(_ shelfID: UUID, _ change: (inout Shelf) -> Void) {
        save(
            shelves.map { shelf in
                var shelf = shelf
                if shelf.id == shelfID { change(&shelf) }
                return shelf
            })
    }

    private func save(_ newShelves: [Shelf]) {
        let newItems = newShelves.flatMap(\.items)
        for path in getUnusedShelfCopies(old: items, new: newItems) {
            // Only folders the shelf made, in case a copy was moved out of it since.
            let folder = URL(filePath: path).deletingLastPathComponent()
            if folder.deletingLastPathComponent().standardizedFileURL == copiesDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        selection.formIntersection(newItems.map(\.id))
        shelves = newShelves
        let shelvesURL = shelvesURL
        writeQueue.async {
            do {
                try JSONEncoder().encode(newShelves).write(to: shelvesURL, options: .atomic)
            } catch {
                print("CocoNotch couldn't save the shelves: \(error)")
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

/// Takes drops on a shelf, or with no shelf, anywhere on the notch, open or closed. Tabs and Home cards being
/// reordered are left to their own drop.
struct ShelfDropDelegate: DropDelegate {
    var shelfID: UUID?
    var isEnabled = true
    private let store = ShelfStore.shared
    private var targetID: String { shelfID?.uuidString ?? notchDropTargetID }

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && !info.hasItemsConforming(to: [widgetDragType])
    }

    func dropEntered(info: DropInfo) {
        store.dropTargetIDs.insert(targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: store.draggedIDs.isEmpty ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        store.dropTargetIDs.remove(targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        // The notch-wide target also covers the shelves, so a shelf under the pointer wins over the default one.
        let shelfID =
            shelfID
            ?? store.shelves.first { store.dropTargetIDs.contains($0.id.uuidString) }?.id
        store.dropTargetIDs.remove(targetID)
        store.didDrop = true
        if store.draggedIDs.isEmpty {
            store.add(info.itemProviders(for: [.item]), to: shelfID)
            return true
        }
        guard let shelfID else { return false }
        store.move(store.draggedIDs, to: shelfID)
        store.draggedIDs = []
        return true
    }
}

private struct ShelfView: View {
    @State private var query = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedShelfID: UUID?
    private let store = ShelfStore.shared

    var body: some View {
        let shelves = filterShelves(store.shelves, query: query)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search shelves and files", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        let id = store.addShelf()
                        query = ""
                        focusedShelfID = id
                        withAnimation { proxy.scrollTo(id) }
                    } label: {
                        Label("New Shelf", systemImage: "plus")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(shelves) { shelf in
                            ShelfSection(shelf: shelf, focusedShelfID: $focusedShelfID)
                                .id(shelf.id)
                        }
                        if shelves.isEmpty {
                            Text("No shelf or file matches.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                    .background(OverlayScroller())
                }
                // As tall as the shelves, up to what fits under the search bar in the notch.
                .frame(height: min(contentHeight, 236))
            }
        }
        .onAppear { store.refresh() }
    }
}

/// Switches the enclosing scroll view to thin overlay scrollers, since the always-shown kind is heavy in the notch.
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The view joins the scroll view only once it's in the window.
        Task { nsView.enclosingScrollView?.scrollerStyle = .overlay }
    }
}

private enum ShelfConfirmation {
    case clear
    case delete
}

private struct ShelfSection: View {
    let shelf: Shelf
    var focusedShelfID: FocusState<UUID?>.Binding
    /// Asked inline, since an alert opens outside the notch and leaving the notch closes it.
    @State private var confirmation: ShelfConfirmation?
    private let store = ShelfStore.shared

    var body: some View {
        let targets = store.getItems(getShelfSelectedOrAll(shelf.items.map(\.id), selection: store.selection))
        let isTargeted = store.dropTargetIDs.contains(shelf.id.uuidString)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // On one baseline, so the smaller details sit on the name's line rather than centred against it.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField(
                        "Untitled", text: Binding(get: { shelf.name }, set: { store.rename(shelf.id, to: $0) })
                    )
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused(focusedShelfID, equals: shelf.id)
                    .fixedSize()
                    if store.defaultShelfID == shelf.id {
                        Text("Primary")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.12), in: Capsule())
                            .help("Files dropped on the closed notch are added to this shelf.")
                    }
                    Text(formatShelfSummary(shelf.items))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let confirmation {
                    Text(confirmation == .clear ? "Clear this shelf?" : "Delete this shelf?")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { self.confirmation = nil }
                    Button(confirmation == .clear ? "Clear" : "Delete") {
                        if confirmation == .clear { store.clear(shelf.id) } else { store.deleteShelf(shelf.id) }
                        self.confirmation = nil
                    }
                    .foregroundStyle(.red)
                } else {
                    if !shelf.items.isEmpty {
                        Button("Quick Look", systemImage: "eye") { store.showQuickLook(targets) }
                            .help("Quick Look")
                        Button("AirDrop", systemImage: "airplayaudio") { store.sendWithAirDrop(targets) }
                            .help("Send with AirDrop")
                        ShareLink(items: targets.compactMap(store.getURL)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .help("Share")
                    }
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Rename") { focusedShelfID.wrappedValue = shelf.id }
                        if store.defaultShelfID != shelf.id {
                            Button("Set as Primary") {
                                UserDefaults.standard.set(shelf.id.uuidString, forKey: defaultShelfKey)
                            }
                        }
                        Divider()
                        Button("Clear Shelf") { confirmation = .clear }
                            .disabled(shelf.items.isEmpty)
                        Button("Delete Shelf") { confirmation = .delete }
                            .disabled(store.shelves.count == 1)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
            .font(.callout)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            Group {
                if shelf.items.isEmpty {
                    Text("Drop files, links or text here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfTile(
                                    item: item, isSelected: store.selection.contains(item.id),
                                    isMissing: store.missingIDs.contains(item.id))
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    // As tall as the tallest tile, rather than stretching to fill the shelf list.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(isTargeted ? 0.1 : 0.04))
                    .strokeBorder(
                        Color.primary.opacity(isTargeted ? 0.4 : 0.12),
                        style: StrokeStyle(lineWidth: 1, dash: shelf.items.isEmpty ? [5] : []))
            }
            // A click between tiles clears the selection, like Finder.
            .onTapGesture { store.selection = [] }
        }
        .onDrop(of: [.item], delegate: ShelfDropDelegate(shelfID: shelf.id))
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
        }
        .padding(6)
        .frame(width: 84)
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
        store.draggedIDs = getShelfTargets(clicked: item.id, selection: store.selection)
        let items = store.getItems(store.draggedIDs)
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
        // Out of CocoNotch it's always a copy, so the original never moves; inside, it moves to another shelf.
        context == .outsideApplication ? .copy : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A move to another shelf already cleared the dragged items, so only drags out are removed.
        if !operation.isEmpty, readSetting(removesAfterDragOutKey, default: false) { store.remove(store.draggedIDs) }
        store.draggedIDs = []
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
    @AppStorage(defaultShelfKey) private var storedDefaultShelfID = ""
    private let store = ShelfStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open the notch when a drag is over it", isOn: $opensOnDragHover)
                Picker(
                    "Primary shelf",
                    selection: Binding(
                        get: { store.defaultShelfID?.uuidString ?? "" }, set: { storedDefaultShelfID = $0 })
                ) {
                    ForEach(store.shelves) { shelf in
                        Text(shelf.name.isEmpty ? "Untitled" : shelf.name).tag(shelf.id.uuidString)
                    }
                }
            } header: {
                Text("Dropping")
            } footer: {
                Text(
                    "Files dropped on the closed notch are added to the primary shelf. With the notch open, drop on any shelf; drag items between shelves to move them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep a copy of dropped files", isOn: $copiesFiles)
                Toggle("Remove items after dragging them out", isOn: $removesAfterDragOut)
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
