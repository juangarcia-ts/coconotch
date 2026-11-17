/// The sizes the open notch can be shown at, as a multiple of its normal size.
public let notchScaleRange = 0.8...1.6

/// Turns a stored size into one that is safe to lay out with: missing, zero, negative or non-finite values become
/// 1, and anything else is kept within `notchScaleRange`.
public func clampNotchScale(_ stored: Double?) -> Double {
    guard let stored, stored.isFinite, stored > 0 else { return 1 }
    return min(max(stored, notchScaleRange.lowerBound), notchScaleRange.upperBound)
}

/// The size the open notch is drawn at for a stored size; 100% is 10% bigger than the layout's own points.
public func getAppliedNotchScale(_ stored: Double?) -> Double {
    clampNotchScale(stored) * 1.1
}

/// The room to leave above the open notch's content, in its unscaled points, so a camera housing that doesn't scale
/// never covers it.
public func getCameraHousingInset(height: Double, notchScale: Double) -> Double {
    height / notchScale
}
