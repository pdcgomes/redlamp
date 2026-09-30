import CoreGraphics

/// Sizes and spacing of the Develop panels.
public enum Metrics {
    public static let labelWidth: CGFloat = 76
    public static let valueWidth: CGFloat = 44
    public static let rowHeight: CGFloat = 20
    /// Between a row's label, track and value.
    public static let rowSpacing: CGFloat = 6
    /// Between the rows of a panel.
    public static let panelRowSpacing: CGFloat = 3
    public static let panelPadding: CGFloat = 14
    public static let panelBottomPadding: CGFloat = 14
    public static let panelHeaderHeight: CGFloat = 32
    public static let controlRowMinHeight: CGFloat = 24
    public static let thumbSize: CGFloat = 11
    public static let trackHeight: CGFloat = 16
    public static let subsectionTopPadding: CGFloat = 10
    public static let subsectionBottomPadding: CGFloat = 2
    /// The small gap Lightroom leaves between slider groups (Exposure/Contrast, then
    /// Highlights…).
    public static let groupGap: CGFloat = 4
}
