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
