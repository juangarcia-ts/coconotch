import Foundation

/// Something dropped on the shelf. Files are kept as bookmarks so they follow the original when it moves.
public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case text
        case link
    }

    public var id: UUID
    public var kind: Kind
    /// A file's last known path, the text, or the link's address.
    public var value: String
    public var bookmark: Data?
    /// Whether the file is CocoNotch's own copy, deleted from disk with the item.
    public var isCopy: Bool
    public var byteCount: Int?
    public var addedAt: Date

    public init(
        id: UUID = UUID(), kind: Kind, value: String, bookmark: Data? = nil, isCopy: Bool = false,
        byteCount: Int? = nil, addedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.bookmark = bookmark
        self.isCopy = isCopy
        self.byteCount = byteCount
        self.addedAt = addedAt
    }
}

/// Adds new items after the ones already there, skipping any the shelf already holds.
public func addShelfItems(_ newItems: [ShelfItem], to items: [ShelfItem]) -> [ShelfItem] {
    var result = items
    for item in newItems where !result.contains(where: { $0.kind == item.kind && $0.value == item.value }) {
        result.append(item)
    }
    return result
}

/// Copies the old list owned that the new one doesn't, to delete from disk.
public func getUnusedShelfCopies(old: [ShelfItem], new: [ShelfItem]) -> Set<String> {
    let copies = { (items: [ShelfItem]) in Set(items.filter(\.isCopy).map(\.value)) }
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

/// The item's one-line name: a file's name, the first line of text, or a link without its scheme.
public func getShelfItemTitle(_ item: ShelfItem) -> String {
    switch item.kind {
    case .file:
        return URL(filePath: item.value).lastPathComponent
    case .text:
        let firstLine = item.value.prefix(500).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return String((firstLine ?? "").prefix(80))
    case .link:
        guard let url = URL(string: item.value), let host = url.host() else { return item.value }
        return host + (url.path() == "/" ? "" : url.path())
    }
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
