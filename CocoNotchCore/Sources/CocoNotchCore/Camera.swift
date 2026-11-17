/// The camera to show: the one the user picked while it is connected, else the system default, else any camera.
public func getCameraID(pickedID: String, defaultID: String?, availableIDs: [String]) -> String? {
    if availableIDs.contains(pickedID) { return pickedID }
    if let defaultID, availableIDs.contains(defaultID) { return defaultID }
    return availableIDs.first
}
