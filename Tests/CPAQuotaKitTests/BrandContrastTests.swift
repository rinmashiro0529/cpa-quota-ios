import Foundation
import Testing
import CPAQuotaUI

@Suite("Interactive text contrast")
struct BrandContrastTests {
    @Test func actionTextPassesEveryOpaqueContentSurfaceInBothAppearances() {
        for dark in [false, true] {
            let backgrounds = dark
                ? [(0.145, 0.137, 0.125), (0.075, 0.071, 0.067), (0.180, 0.173, 0.161)]
                : [(1.000, 0.992, 0.976), (0.980, 0.973, 0.957), (0.941, 0.922, 0.886)]
            for high in [false, true] {
                let foreground = BrandActionColor.resolve(isDark: dark, increasedContrast: high)
                let foregroundLuminance = luminance(foreground.red, foreground.green, foreground.blue)
                for background in backgrounds {
                    let backgroundLuminance = luminance(background.0, background.1, background.2)
                    let ratio = (max(foregroundLuminance, backgroundLuminance) + 0.05)
                        / (min(foregroundLuminance, backgroundLuminance) + 0.05)
                    #expect(ratio >= (high ? 7.0 : 4.5), "dark=\(dark), increasedContrast=\(high), ratio=\(ratio)")
                }
            }
        }
    }

    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
