/// The id `offset` rows from `current`, held at the ends of the list; nil when `current` isn't in it.
public func getMovedSelection<ID: Equatable>(in ids: [ID], from current: ID?, by offset: Int) -> ID? {
    guard let index = ids.firstIndex(where: { $0 == current }) else { return nil }
    return ids[max(0, min(ids.count - 1, index + offset))]
}
