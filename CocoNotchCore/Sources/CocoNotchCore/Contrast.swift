/// Whether dark text reads better than white on a background, from its linear sRGB components.
/// Uses the WCAG luminance threshold where black and white have equal contrast.
public func shouldUseDarkText(linearRed: Double, linearGreen: Double, linearBlue: Double) -> Bool {
    let luminance = 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    return luminance > 0.179
}
