#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaChat

/// Compact composer pill that displays the active reasoning effort and opens
/// a Codex-style discrete slider popover (or sheet at accessibility text sizes).
struct ChatReasoningTriggerButton: View {
    let effort: ChatReasoningEffort
    let onSelect: (ChatReasoningEffort) -> Void
    @State private var isPresented = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isActiveExplicit: Bool {
        effort != .automatic && effort != .off
    }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let trigger = Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: effort.symbolName)
                    .font(.caption.weight(.semibold))
                Text(effort.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isActiveExplicit ? palette.actionTint : palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(pillBackground(palette), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(pillBorder(palette), lineWidth: contrast == .increased ? 1 : 0.75)
                    .allowsHitTesting(false)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel("思考等级")
        .accessibilityValue(effort.title)
        .accessibilityHint("轻点调整思考等级")
        .accessibilityIdentifier("chat.reasoningTrigger")

        if dynamicTypeSize.isAccessibilitySize {
            trigger
                .sheet(isPresented: $isPresented) {
                    NavigationStack {
                        ScrollView {
                            ChatReasoningSliderPopover(effort: effort, onSelect: onSelect)
                                .padding(16)
                        }
                        .navigationTitle("思考等级")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { isPresented = false }
                            }
                        }
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
        } else {
            trigger
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    ChatReasoningSliderPopover(effort: effort, onSelect: onSelect)
                        .frame(width: 288)
                        .padding(14)
                        .presentationCompactAdaptation(.popover)
                }
        }
    }

    private func pillBackground(_ palette: BrandPalette) -> Color {
        if isActiveExplicit {
            return palette.accentSoft
        }
        return palette.insetSurface
    }

    private func pillBorder(_ palette: BrandPalette) -> Color {
        if isActiveExplicit {
            return palette.actionTint.opacity(contrast == .increased ? 0.75 : 0.32)
        }
        return palette.trackBackground
    }
}

/// Floating Codex-style card: active level header with automatic toggle,
/// thick capsule discrete stepped slider, tappable tick labels, and brief description.
struct ChatReasoningSliderPopover: View {
    let effort: ChatReasoningEffort
    let onSelect: (ChatReasoningEffort) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(spacing: 12) {
            ZStack {
                HStack(spacing: 4) {
                    Text(effort.title)
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityIdentifier("chat.reasoningActiveTitle")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textMuted)
                        .accessibilityHidden(true)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        onSelect(.automatic)
                    } label: {
                        Text("自动")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(effort == .automatic ? palette.actionTint : palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                effort == .automatic ? palette.accentSoft : palette.insetSurface,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        effort == .automatic ? palette.actionTint.opacity(0.45) : palette.trackBackground,
                                        lineWidth: 0.75
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                    .accessibilityLabel("思考等级：自动")
                    .accessibilityAddTraits(effort == .automatic ? .isSelected : [])
                    .accessibilityIdentifier("chat.reasoningOption.automatic")
                }
            }

            ChatSteppedReasoningSlider(effort: effort, onSelect: onSelect)

            Text(effort.summary)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.reasoningPopover")
    }
}

/// Inline version used inside `ChatConversationOptionsView` so both entry points
/// share the exact same discrete levels and tactile slider behavior.
struct ChatReasoningInlineSelector: View {
    let effort: ChatReasoningEffort
    let onSelect: (ChatReasoningEffort) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("思考等级")
                    .font(.body)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text(effort.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(effort == .automatic ? palette.textSecondary : palette.actionTint)
                if effort != .automatic {
                    Button("自动") {
                        onSelect(.automatic)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("chat.options.reasoningAutomatic")
                }
            }

            ChatSteppedReasoningSlider(effort: effort, onSelect: onSelect)

            Text(effort.summary)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

/// Thick capsule discrete slider with 6 stops (`off` through `max`), drag + tap-to-jump,
/// haptic tick feedback, and VoiceOver adjustable support.
struct ChatSteppedReasoningSlider: View {
    let effort: ChatReasoningEffort
    let onSelect: (ChatReasoningEffort) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false

    private let levels = ChatReasoningEffort.explicitLevels
    private let trackHeight: CGFloat = 38
    private let thumbDiameter: CGFloat = 32
    private let dotDiameter: CGFloat = 5.5

    private var activeIndex: Int? {
        levels.firstIndex(of: effort)
    }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme, contrast: contrast)
        let fillColor = contrast == .increased ? palette.actionTint : palette.accent

        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = max(trackHeight, proxy.size.width)
                let edgeInset = trackHeight / 2
                let usableWidth = max(1, width - trackHeight)
                let stepCount = max(1, levels.count - 1)
                let stopX: (Int) -> CGFloat = { index in
                    edgeInset + (CGFloat(index) / CGFloat(stepCount)) * usableWidth
                }

                ZStack(alignment: .leading) {
                    // Base capsule track
                    Capsule()
                        .fill(palette.isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.08))
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    palette.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10),
                                    lineWidth: contrast == .increased ? 1.25 : 0.75
                                )
                        }

                    // Active filled bar (off leaves track unfilled; low..max fills through thumb)
                    if let index = activeIndex, index > 0 {
                        let fillWidth = min(width, stopX(index) + edgeInset)
                        Capsule()
                            .fill(fillColor)
                            .frame(width: fillWidth, height: trackHeight)
                    }

                    // Discrete stop dots
                    ForEach(levels.indices, id: \.self) { index in
                        let isFilledDot = activeIndex.map { $0 > 0 && index < $0 } ?? false
                        Circle()
                            .fill(isFilledDot
                                  ? Color.white.opacity(0.55)
                                  : palette.textMuted.opacity(palette.isDark ? 0.7 : 0.55))
                            .frame(width: dotDiameter, height: dotDiameter)
                            .position(x: stopX(index), y: trackHeight / 2)
                            .allowsHitTesting(false)
                    }

                    // Draggable thumb (hidden in `.automatic` so track reads as model-default)
                    if let index = activeIndex {
                        Circle()
                            .fill(Color.white)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.75)
                            }
                            .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .scaleEffect(isDragging && !reduceMotion ? 1.06 : 1)
                            .position(x: stopX(index), y: trackHeight / 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let fraction = min(max((value.location.x - edgeInset) / usableWidth, 0), 1)
                            let targetIndex = Int((fraction * CGFloat(stepCount)).rounded())
                            let target = levels[min(max(targetIndex, 0), levels.count - 1)]
                            if target != effort {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)) {
                                    onSelect(target)
                                }
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: trackHeight)
            .sensoryFeedback(.selection, trigger: effort)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("思考等级滑块")
            .accessibilityValue(effort.title)
            .accessibilityHint("上下轻扫调整思考等级")
            .accessibilityAdjustableAction { direction in
                adjustEffort(direction)
            }
            .accessibilityIdentifier("chat.reasoningSlider")

            // Direct-tap tick labels beneath each stop
            HStack(spacing: 0) {
                ForEach(levels) { level in
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)) {
                            onSelect(level)
                        }
                    } label: {
                        Text(level.compactTickTitle)
                            .font(.caption2.weight(effort == level ? .semibold : .regular))
                            .foregroundStyle(effort == level ? palette.textPrimary : palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("思考等级：\(level.title)")
                    .accessibilityAddTraits(effort == level ? .isSelected : [])
                    .accessibilityIdentifier("chat.reasoningOption.\(level.rawValue)")
                }
            }
        }
    }

    private func adjustEffort(_ direction: AccessibilityAdjustmentDirection) {
        let ordered: [ChatReasoningEffort] = [.automatic] + levels
        guard let current = ordered.firstIndex(of: effort) else { return }
        switch direction {
        case .increment:
            let next = min(current + 1, ordered.count - 1)
            onSelect(ordered[next])
        case .decrement:
            let prev = max(current - 1, 0)
            onSelect(ordered[prev])
        @unknown default:
            break
        }
    }
}
#endif
