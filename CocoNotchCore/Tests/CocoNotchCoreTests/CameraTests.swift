import CocoNotchCore
import Testing

@Test(
    arguments: [
        ("b", "a", ["a", "b"], "b"),  // picked camera is connected
        ("c", "a", ["a", "b"], "a"),  // picked camera was unplugged
        ("", "b", ["a", "b"], "b"),  // nothing picked
        ("", "z", ["a", "b"], "a"),  // default is not in the list
        ("", nil, ["a", "b"], "a"),  // no default
        ("a", "a", [], nil),  // no cameras
    ] as [(String, String?, [String], String?)])
func choosesCamera(pickedID: String, defaultID: String?, availableIDs: [String], expected: String?) {
    #expect(getCameraID(pickedID: pickedID, defaultID: defaultID, availableIDs: availableIDs) == expected)
}
