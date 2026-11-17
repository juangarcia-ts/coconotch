import Foundation
import UniformTypeIdentifiers

/// A file on a shelf, kept as a bookmark so it follows the original when it moves.
public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The file's last known path.
    public var path: String
    public var bookmark: Data?
    /// Whether the file is CocoNotch's own copy, deleted from disk with the item.
    public var isCopy: Bool
    public var byteCount: Int?
    public var addedAt: Date

    public var url: URL { URL(filePath: path) }
    public var name: String { url.lastPathComponent }

    public init(
        id: UUID = UUID(), path: String, bookmark: Data? = nil, isCopy: Bool = false, byteCount: Int? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.isCopy = isCopy
        self.byteCount = byteCount
        self.addedAt = addedAt
    }
}

public enum ShelfDropSource: Equatable, Sendable {
    /// A file on disk, which the shelf points at or copies.
    case fileURL
    /// Data or a promised file in this type, like an image from a browser or a Mail attachment, saved as a copy.
    case data(type: String)
}

/// How to take a file from a drop's types, or nil for text and links, which the shelf doesn't hold.
public func getShelfDropSource(typeIdentifiers: [String]) -> ShelfDropSource? {
    let types = typeIdentifiers.compactMap { UTType($0) }
    if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
    // A dragged picture also carries its link, so an image counts even next to a URL.
    if let image = types.first(where: { $0.conforms(to: .image) }) { return .data(type: image.identifier) }
    if types.contains(where: { $0.conforms(to: .url) || $0.conforms(to: .text) }) { return nil }
    return types.first { $0.conforms(to: .data) }.map { .data(type: $0.identifier) }
}

/// Adds new items after the ones already there, skipping any the shelf already holds.
public func addShelfItems(_ newItems: [ShelfItem], to items: [ShelfItem]) -> [ShelfItem] {
    var result = items
    for item in newItems where !result.contains(where: { $0.path == item.path }) {
        result.append(item)
    }
    return result
}

/// Copies the old list owned that the new one doesn't, to delete from disk.
public func getUnusedShelfCopies(old: [ShelfItem], new: [ShelfItem]) -> Set<String> {
    let copies = { (items: [ShelfItem]) in Set(items.filter(\.isCopy).map(\.path)) }
    return copies(old).subtracting(copies(new))
}

public enum ShelfFileStatus: Equatable, Sendable {
    case available
    /// The file moved or the bookmark aged; save a fresh bookmark for the new path.
    case refresh(path: String)
    /// The file went to the Trash, which the user means as a removal.
    case trashed
    /// The file can't be found, for example on an unplugged drive.
    case missing
}

/// What to do with a file item after resolving its bookmark.
public func getShelfFileStatus(savedPath: String, resolvedPath: String?, isStale: Bool) -> ShelfFileStatus {
    guard let resolvedPath else { return .missing }
    // A volume's own trash is .Trashes; the home folder's is .Trash.
    if resolvedPath.contains("/.Trash/") || resolvedPath.contains("/.Trashes/") { return .trashed }
    return isStale || resolvedPath != savedPath ? .refresh(path: resolvedPath) : .available
}

/// "3 items · 12 MB", leaving the size out when no file's size is known.
public func formatShelfSummary(_ items: [ShelfItem]) -> String {
    let count = items.count == 1 ? "1 item" : "\(items.count) items"
    let sizes = items.compactMap(\.byteCount)
    guard !sizes.isEmpty else { return count }
    return count + " · " + ByteCountFormatter.string(fromByteCount: Int64(sizes.reduce(0, +)), countStyle: .file)
}

/// The selection after a click: a plain click selects only that item, ⌘ toggles it, and ⇧ extends from the anchor.
public func selectShelfItems(
    clicked: UUID, in ids: [UUID], selection: Set<UUID>, anchor: UUID?, isToggling: Bool, isExtending: Bool
) -> (selection: Set<UUID>, anchor: UUID) {
    if isExtending, let anchor, let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: clicked) {
        return (selection.union(ids[min(start, end)...max(start, end)]), anchor)
    }
    if isToggling {
        return (selection.symmetricDifference([clicked]), clicked)
    }
    return ([clicked], clicked)
}

/// The items an action or drag on `clicked` applies to: the whole selection if it's part of it, otherwise just it.
public func getShelfTargets(clicked: UUID, selection: Set<UUID>) -> Set<UUID> {
    selection.contains(clicked) ? selection : [clicked]
}

/// The toolbar acts on the selected items, or on every item when none is selected, in shelf order.
public func getShelfSelectedOrAll(_ ids: [UUID], selection: Set<UUID>) -> [UUID] {
    let selected = ids.filter(selection.contains)
    return selected.isEmpty ? ids : selected
}

/// A named list of items; the notch holds as many as the user makes.
public struct Shelf: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [ShelfItem]

    public init(id: UUID = UUID(), name: String, items: [ShelfItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// "Shelf", then "Shelf 2", "Shelf 3"… skipping names already taken.
public func makeShelfName(existing: [Shelf]) -> String {
    let names = Set(existing.map(\.name))
    return (1...).lazy.map { $0 == 1 ? "Shelf" : "Shelf \($0)" }.first { !names.contains($0) } ?? "Shelf"
}

/// Moves the items to the end of the target shelf; one the target already holds is dropped as a duplicate.
public func moveShelfItems(_ ids: Set<UUID>, to shelfID: UUID, in shelves: [Shelf]) -> [Shelf] {
    let moved = shelves.flatMap(\.items).filter { ids.contains($0.id) }
    return shelves.map { shelf in
        var shelf = shelf
        shelf.items.removeAll { ids.contains($0.id) }
        if shelf.id == shelfID { shelf.items = addShelfItems(moved, to: shelf.items) }
        return shelf
    }
}

/// The shelves and items a search shows: a shelf whose name matches shows everything in it; otherwise only the items
/// whose name matches, and shelves left with none are hidden.
public func filterShelves(_ shelves: [Shelf], query: String) -> [Shelf] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return shelves }
    return shelves.compactMap { shelf in
        if shelf.name.localizedStandardContains(query) { return shelf }
        var shelf = shelf
        shelf.items = shelf.items.filter { $0.name.localizedStandardContains(query) }
        return shelf.items.isEmpty ? nil : shelf
    }
}

/// The file name for a copy, from the name the source app suggests: only its last component, so a name like
/// `../x` can't place the copy outside its folder, keeping the source file's extension when the name has none.
public func makeShelfCopyName(suggestedName: String?, sourceName: String) -> String {
    let suggested = suggestedName.map { ($0 as NSString).lastPathComponent } ?? ""
    var name = ["", ".", "..", "/"].contains(suggested) ? sourceName : suggested
    let sourceExtension = (sourceName as NSString).pathExtension
    if (name as NSString).pathExtension.isEmpty, !sourceExtension.isEmpty { name += "." + sourceExtension }
    return name
}

/// The folder to delete with a copy: its own folder, only when that sits directly in the shelf's copies folder, in
/// case the copy was moved out since.
public func getShelfCopyFolder(path: String, copiesPath: String) -> String? {
    let folder = (path as NSString).deletingLastPathComponent
    let isOwned =
        (folder as NSString).deletingLastPathComponent == (copiesPath as NSString).standardizingPath
    return isOwned ? folder : nil
}

/// The shelf a drop lands on: the one asked for if it still exists, since it may be deleted while a drop loads,
/// otherwise the first.
public func getShelfDropTarget(_ shelfID: UUID?, in shelves: [Shelf]) -> UUID? {
    shelves.contains { $0.id == shelfID } ? shelfID : shelves.first?.id
}

public enum ShelfMouseDownAction: Equatable, Sendable {
    case open
    case select
    /// A plain press on a selected item keeps the selection, so the whole selection can be dragged.
    case keepSelection
}

public func getShelfMouseDownAction(clickCount: Int, isSelected: Bool, isModifying: Bool) -> ShelfMouseDownAction {
    if clickCount == 2 { return .open }
    return isSelected && !isModifying ? .keepSelection : .select
}

/// A plain click that didn't turn into a drag narrows the selection down to the clicked item.
public func shouldNarrowShelfSelection(didDrag: Bool, clickCount: Int, isModifying: Bool) -> Bool {
    !didDrag && clickCount == 1 && !isModifying
}

public enum ShelfDragChange: Equatable, Sendable {
    /// Show the Shelf tab, opening the notch if it's closed.
    case show
    case close
    /// After a drop the pointer is still on the notch, so hovering decides when it closes.
    case leaveToHover
    case none
}

/// What the notch does when a file drag starts or stops being over it.
public func getShelfDragChange(
    isTargeted: Bool, isExpanded: Bool, opensOnDragHover: Bool, isOpenedByDrag: Bool, didDrop: Bool,
    isHovering: Bool
) -> ShelfDragChange {
    if isTargeted { return isExpanded || opensOnDragHover ? .show : .none }
    guard isOpenedByDrag else { return .none }
    if didDrop { return .leaveToHover }
    return isHovering ? .none : .close
}

/// Delete or Forward Delete removes the selected items, but only in a notch that has the keyboard and isn't typing.
public func shouldRemoveShelfSelection(keyCode: UInt16, isNotchKey: Bool, isTyping: Bool, hasSelection: Bool) -> Bool {
    let deleteKeyCodes: Set<UInt16> = [51, 117]
    return deleteKeyCodes.contains(keyCode) && isNotchKey && !isTyping && hasSelection
}
