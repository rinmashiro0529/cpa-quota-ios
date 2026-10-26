#if canImport(SwiftUI)
import SwiftUI

extension CPAThemeMode {
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public struct LiquidGlassPalette: Sendable {
    public let colorScheme: ColorScheme

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var isDark: Bool {
        colorScheme == .dark
    }

    // Claude Warm Parchment (Light) vs Warm Obsidian (Dark)
    public var canvasBase: Color {
        isDark
            ? Color(red: 0.075, green: 0.071, blue: 0.067) // #131211
            : Color(red: 0.980, green: 0.973, blue: 0.957) // #FAF8F4
    }

    public var textPrimary: Color {
        isDark
            ? Color(red: 0.957, green: 0.941, blue: 0.918) // #F4F0EA
            : Color(red: 0.094, green: 0.090, blue: 0.082) // #181715
    }

    public var textSecondary: Color {
        isDark
            ? Color(red: 0.651, green: 0.627, blue: 0.596) // #A6A098
            : Color(red: 0.384, green: 0.369, blue: 0.345) // #625E58
    }

    public var textMuted: Color {
        isDark
            ? Color(red: 0.431, green: 0.416, blue: 0.388) // #6E6A63
            : Color(red: 0.580, green: 0.561, blue: 0.529) // #948F87
    }

    // Claude Terracotta Accent
    public var accent: Color {
        isDark
            ? Color(red: 0.886, green: 0.502, blue: 0.376) // #E28060
            : Color(red: 0.824, green: 0.427, blue: 0.298) // #D26D4C
    }

    public var accentSoft: Color {
        accent.opacity(isDark ? 0.18 : 0.13)
    }

    public var statusOK: Color {
        isDark
            ? Color(red: 0.322, green: 0.718, blue: 0.533)
            : Color(red: 0.157, green: 0.455, blue: 0.329)
    }

    public var statusWarn: Color {
        isDark
            ? Color(red: 0.918, green: 0.627, blue: 0.306)
            : Color(red: 0.722, green: 0.431, blue: 0.133)
    }

    public var statusError: Color {
        isDark
            ? Color(red: 0.918, green: 0.427, blue: 0.361)
            : Color(red: 0.749, green: 0.263, blue: 0.196)
    }

    public var trackBackground: Color {
        isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
    }

    public var cardTintOverlay: Color {
        isDark
            ? Color(red: 0.145, green: 0.137, blue: 0.125).opacity(0.56)
            : Color(red: 1.000, green: 0.992, blue: 0.976).opacity(0.62)
    }

    public var pillTintOverlay: Color {
        isDark
            ? Color(red: 0.180, green: 0.173, blue: 0.161).opacity(0.70)
            : Color(red: 0.941, green: 0.922, blue: 0.886).opacity(0.74)
    }

    public var specularRimGradient: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color.white.opacity(0.22), Color.white.opacity(0.06), Color.white.opacity(0.03)]
                : [Color.white.opacity(0.95), Color.white.opacity(0.45), Color.black.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

public struct AmbientGlassCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        ZStack {
            palette.canvasBase
                .ignoresSafeArea()

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height

                Circle()
                    .fill(palette.accent.opacity(palette.isDark ? 0.16 : 0.12))
                    .frame(width: width * 0.78, height: width * 0.78)
                    .blur(radius: 64)
                    .offset(x: -width * 0.22, y: -height * 0.08)

                Circle()
                    .fill(
                        (palette.isDark
                            ? Color(red: 0.45, green: 0.36, blue: 0.28)
                            : Color(red: 0.72, green: 0.64, blue: 0.50))
                            .opacity(palette.isDark ? 0.15 : 0.16)
                    )
                    .frame(width: width * 0.72, height: width * 0.72)
                    .blur(radius: 72)
                    .offset(x: width * 0.36, y: height * 0.18)

                Circle()
                    .fill(
                        Color(red: 0.32, green: 0.48, blue: 0.62)
                            .opacity(palette.isDark ? 0.12 : 0.08)
                    )
                    .frame(width: width * 0.80, height: width * 0.80)
                    .blur(radius: 80)
                    .offset(x: width * 0.05, y: height * 0.62)
            }
            .ignoresSafeArea()
        }
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public let cornerRadius: CGFloat
    public let prominent: Bool

    public init(cornerRadius: CGFloat = 26, prominent: Bool = false) {
        self.cornerRadius = cornerRadius
        self.prominent = prominent
    }

    public func body(content: Content) -> some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(prominent ? .regularMaterial : .ultraThinMaterial)
                    shape.fill(palette.cardTintOverlay)
                }
                .shadow(
                    color: Color.black.opacity(palette.isDark ? 0.42 : 0.07),
                    radius: prominent ? 22 : 14,
                    x: 0,
                    y: prominent ? 10 : 6
                )
            }
            .overlay {
                shape.strokeBorder(palette.specularRimGradient, lineWidth: 1)
            }
    }
}

public struct LiquidGlassPillModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 18) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(palette.pillTintOverlay)
                }
            }
            .overlay {
                shape.strokeBorder(palette.specularRimGradient, lineWidth: 0.8)
            }
    }
}

extension View {
    public func liquidGlassCard(cornerRadius: CGFloat = 26, prominent: Bool = false) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, prominent: prominent))
    }

    public func liquidGlassPill(cornerRadius: CGFloat = 18) -> some View {
        modifier(LiquidGlassPillModifier(cornerRadius: cornerRadius))
    }
}
#endif
