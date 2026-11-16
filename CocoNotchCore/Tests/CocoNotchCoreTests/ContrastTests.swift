import CocoNotchCore
import Testing

@Test(arguments: [
    (0.0, 0.0, 0.0, false),  // black
    (1.0, 1.0, 1.0, true),  // white
    (1.0, 1.0, 0.0, true),  // yellow
    (0.0, 0.0, 1.0, false),  // blue
    (0.05, 0.05, 0.05, false),  // dark gray
])
func choosesTextColor(red: Double, green: Double, blue: Double, isDark: Bool) {
    #expect(shouldUseDarkText(linearRed: red, linearGreen: green, linearBlue: blue) == isDark)
}
