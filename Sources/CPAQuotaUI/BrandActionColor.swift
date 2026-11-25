import Foundation

/// Opaque sRGB text colors. Decorative terracotta remains separate so using a
/// brand fill never silently changes the contrast of small interactive text.
public struct BrandActionColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public static func resolve(isDark: Bool, increasedContrast: Bool) -> BrandActionColor {
        switch (isDark, increasedContrast) {
        case (false, false): BrandActionColor(red: 0.65, green: 0.25, blue: 0.14)
        case (false, true): BrandActionColor(red: 0.50, green: 0.17, blue: 0.08)
        case (true, false): BrandActionColor(red: 0.96, green: 0.64, blue: 0.49)
        case (true, true): BrandActionColor(red: 1.00, green: 0.78, blue: 0.65)
        }
    }
}

/// Opaque sRGB colors for muted metadata text (timestamps, model IDs, token counts)
/// that still satisfy WCAG AA (>= 4.5:1) at standard contrast and AAA (>= 7.0:1)
/// under Increased Contrast across all opaque content surfaces.
public struct BrandMutedTextColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public static func resolve(isDark: Bool, increasedContrast: Bool) -> BrandMutedTextColor {
        switch (isDark, increasedContrast) {
        case (false, false): BrandMutedTextColor(red: 0.431, green: 0.412, blue: 0.384) // #6E6962
        case (false, true): BrandMutedTextColor(red: 0.290, green: 0.278, blue: 0.259)  // #4A4742
        case (true, false): BrandMutedTextColor(red: 0.596, green: 0.573, blue: 0.541)  // #98928A
        case (true, true): BrandMutedTextColor(red: 0.745, green: 0.722, blue: 0.690)   // #BEB8B0
        }
    }
}
