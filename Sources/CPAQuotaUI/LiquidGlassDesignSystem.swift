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

public struct BrandPalette: Sendable {
    public let colorScheme: ColorScheme

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    public var isDark: Bool {
        colorScheme == .dark
    }

    // Original brand values: warm parchment and warm obsidian.
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

    // Preserve the original terracotta in both appearances.
    public var accent: Color {
        isDark
            ? Color(red: 0.886, green: 0.502, blue: 0.376) // #E28060
            : Color(red: 0.824, green: 0.427, blue: 0.298) // #D26D4C
    }

    public var actionTint: Color { accent }

    /// The original dark brand ink stays readable on either terracotta tint.
    /// Dark appearance's light textPrimary is intended for dark content surfaces,
    /// not for a prominent control filled with the lighter accent.
    public var textOnAccent: Color {
        Color(red: 0.094, green: 0.090, blue: 0.082)
    }

    /// Opaque content surfaces, deliberately separate from the system control layer.
    public var contentSurface: Color {
        isDark
            ? Color(red: 0.145, green: 0.137, blue: 0.125)
            : Color(red: 1.000, green: 0.992, blue: 0.976)
    }

    public var insetSurface: Color {
        isDark
            ? Color(red: 0.180, green: 0.173, blue: 0.161)
            : Color(red: 0.941, green: 0.922, blue: 0.886)
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


}

/// A content canvas, not a substitute for Liquid Glass. It remains readable
/// under Reduce Transparency and does not add decorative continuous rendering.
public struct BrandCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        BrandPalette(colorScheme: colorScheme).canvasBase
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

public enum QuotaTypography {
    public static var brandTitle: Font { .system(.title2, design: .serif).weight(.semibold) }
    public static var brandHeadline: Font { .system(.headline, design: .serif) }
    public static var data: Font { .system(.body, design: .monospaced) }
    public static var dataDetail: Font { .system(.subheadline, design: .monospaced) }
}

public struct QuotaContentSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    public let cornerRadius: CGFloat
    public let prominent: Bool

    public init(cornerRadius: CGFloat = 20, prominent: Bool = false) {
        self.cornerRadius = cornerRadius
        self.prominent = prominent
    }

    public func body(content: Content) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(palette.contentSurface, in: shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? palette.textSecondary : palette.trackBackground,
                    lineWidth: contrast == .increased || prominent ? 1 : 0.5
                )
                .allowsHitTesting(false)
            }
    }
}

private struct QuotaPrimaryButtonStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(palette.actionTint)
                .foregroundStyle(palette.textOnAccent)
                .controlSize(.large)
        } else {
            // The original accent is retained. A readable foreground on a
            // bordered control avoids imposing low-contrast white-on-accent.
            content
                .buttonStyle(.bordered)
                .tint(palette.actionTint)
                .foregroundStyle(palette.textPrimary)
                .controlSize(.large)
        }
    }
}

private struct QuotaSecondaryButtonStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            content
                .buttonStyle(.bordered)
                .foregroundStyle(palette.textPrimary)
                .controlSize(.large)
        }
    }
}

/// Groups nearby glass controls; callers own layout and may switch to VStack
/// for large Dynamic Type. Do not wrap dashboard cards or a complete page.
public struct NativeGlassActionGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    public func quotaContentSurface(cornerRadius: CGFloat = 20, prominent: Bool = false) -> some View {
        modifier(QuotaContentSurfaceModifier(cornerRadius: cornerRadius, prominent: prominent))
    }

    public func quotaPrimaryButtonStyle() -> some View {
        modifier(QuotaPrimaryButtonStyleModifier())
    }

    public func quotaSecondaryButtonStyle() -> some View {
        modifier(QuotaSecondaryButtonStyleModifier())
    }
}

#endif
