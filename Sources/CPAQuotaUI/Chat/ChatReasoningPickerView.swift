#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaChat

/// Compact composer pill that displays the active reasoning effort and opens
/// a Codex-style discrete slider popover (or sheet at accessibility text sizes).
struct ChatReasoningTriggerButton: View {
    let effort: ChatReasoningEffort
    var activeResolutionNotice: String? = nil
    let onSelect: (ChatReasoningEffort) -> Void
    @State private var isPresented = false
    @Environment(\.brandPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isActiveExplicit: Bool {
        effort != .automatic && effort != .off
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            triggerButton
                .sheet(isPresented: $isPresented) {
                    NavigationStack {
                        ScrollView {
                            ChatReasoningSliderPopover(
                                effort: effort,
                                activeResolutionNotice: activeResolutionNotice,
                                onSelect: onSelect
                            )
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
                    .brandPaletteEnvironment()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
        } else {
            triggerButton
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    ChatReasoningSliderPopover(
                        effort: effort,
                        activeResolutionNotice: activeResolutionNotice,
                        onSelect: onSelect
                    )
                    .frame(width: 288)
                    .padding(14)
                    .brandPaletteEnvironment()
                    .presentationCompactAdaptation(.popover)
                }
        }
    }

    private var triggerButton: some View {
        Button {
            isPresented.toggle()
        } label: {
            triggerPillLabel
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel("思考等级")
        .accessibilityValue(effort.title)
        .accessibilityHint(activeResolutionNotice ?? "轻点调整思考等级")
        .accessibilityIdentifier("chat.reasoningTrigger")
    }

    private var triggerPillLabel: some View {
        let borderWidth: CGFloat = palette.contrast == .increased ? 1 : 0.75
        return HStack(spacing: 4) {
            Image(systemName: effort.symbolName)
                .font(.caption.weight(.semibold))
            Text(effort.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(isActiveExplicit ? palette.actionTint : palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(minWidth: 72, minHeight: 36, maxHeight: 36)
        .background(pillBackground, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(pillBorder, lineWidth: borderWidth)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if activeResolutionNotice != nil {
                Circle()
                    .fill(palette.statusWarn)
                    .frame(width: 6, height: 6)
                    .padding(.top, 3)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var pillBackground: Color {
        if isActiveExplicit {
            return palette.accentSoft
        }
        return palette.insetSurface
    }

    private var pillBorder: Color {
        if isActiveExplicit {
            return palette.actionTint.opacity(palette.contrast == .increased ? 0.75 : 0.32)
        }
        return palette.trackBackground
    }
}

/// Floating Codex-style card: active level header with automatic toggle,
/// thick capsule discrete stepped slider, tappable tick labels, and brief description.
struct ChatReasoningSliderPopover: View {
    let effort: ChatReasoningEffort
    var activeResolutionNotice: String? = nil
    let onSelect: (ChatReasoningEffort) -> Void
    @State private var previewEffort: ChatReasoningEffort?
    @Environment(\.brandPalette) private var palette

    private var displayedEffort: ChatReasoningEffort {
        previewEffort ?? effort
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Text(displayedEffort == .automatic ? "思考等级" : displayedEffort.title)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityIdentifier("chat.reasoningActiveTitle")

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        previewEffort = nil
                        onSelect(.automatic)
                    } label: {
                        Text("自动")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(displayedEffort == .automatic ? palette.actionTint : palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                displayedEffort == .automatic ? palette.accentSoft : palette.insetSurface,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        displayedEffort == .automatic ? palette.actionTint.opacity(0.45) : palette.trackBackground,
                                        lineWidth: 0.75
                                    )
                            }
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("思考等级：自动")
                    .accessibilityAddTraits(displayedEffort == .automatic ? .isSelected : [])
                    .accessibilityIdentifier("chat.reasoningOption.automatic")
                }
            }

            ChatSteppedReasoningSlider(effort: effort, onPreview: { previewEffort = $0 }, onSelect: onSelect)

            Text(displayedEffort.summary)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)

            if let activeResolutionNotice, previewEffort == nil {
                Label(activeResolutionNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(palette.statusWarn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    @State private var previewEffort: ChatReasoningEffort?
    @Environment(\.brandPalette) private var palette

    private var displayedEffort: ChatReasoningEffort {
        previewEffort ?? effort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("思考等级")
                    .font(.body)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 8)
                Text(displayedEffort.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(displayedEffort == .automatic ? palette.textSecondary : palette.actionTint)
                if displayedEffort != .automatic {
                    Button {
                        previewEffort = nil
                        onSelect(.automatic)
                    } label: {
                        Text("自动")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.actionTint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.accentSoft, in: Capsule())
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.options.reasoningAutomatic")
                }
            }

            ChatSteppedReasoningSlider(effort: effort, onPreview: { previewEffort = $0 }, onSelect: onSelect)

            Text(displayedEffort.summary)
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
    var onPreview: ((ChatReasoningEffort?) -> Void)? = nil
    let onSelect: (ChatReasoningEffort) -> Void

    @Environment(\.brandPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var dragEffort: ChatReasoningEffort?

    private let levels = ChatReasoningEffort.explicitLevels
    private let trackHeight: CGFloat = 38
    private let thumbDiameter: CGFloat = 32
    private let dotDiameter: CGFloat = 5.5

    private var displayedEffort: ChatReasoningEffort {
        dragEffort ?? effort
    }

    private var activeIndex: Int? {
        levels.firstIndex(of: displayedEffort)
    }

    var body: some View {
        let isIncreasedContrast = palette.contrast == .increased
        let fillColor = isIncreasedContrast ? palette.actionTint : palette.accent
        let usesDarkAccentInk = palette.isDark && isIncreasedContrast
        let filledDotColor = usesDarkAccentInk ? palette.textOnAccent.opacity(0.65) : Color.white.opacity(0.65)
        let thumbStrokeColor = usesDarkAccentInk ? palette.textOnAccent.opacity(0.85) : Color.black.opacity(0.18)

        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = max(trackHeight, proxy.size.width)
                let edgeInset = trackHeight / 2
                let usableWidth = max(1, width - trackHeight)
                let stepCount = max(1, levels.count - 1)
                let stopX: (Int) -> CGFloat = { index in
                    edgeInset + (CGFloat(index) / CGFloat(stepCount)) * usableWidth
                }
                let levelAtX: (CGFloat) -> ChatReasoningEffort = { x in
                    let fraction = min(max((x - edgeInset) / usableWidth, 0), 1)
                    let targetIndex = Int((fraction * CGFloat(stepCount)).rounded())
                    return levels[min(max(targetIndex, 0), levels.count - 1)]
                }

                ZStack(alignment: .leading) {
                    // Base capsule track
                    Capsule()
                        .fill(palette.trackBackground)
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    isIncreasedContrast ? palette.textSecondary.opacity(0.45) : palette.trackBackground,
                                    lineWidth: isIncreasedContrast ? 1.25 : 0.75
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
                                  ? filledDotColor
                                  : palette.textMuted.opacity(palette.isDark ? 0.75 : 0.65))
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
                                    .strokeBorder(thumbStrokeColor, lineWidth: isIncreasedContrast ? 1.5 : 0.75)
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
                .onTapGesture(coordinateSpace: .local) { location in
                    let target = levelAtX(location.x)
                    guard target != effort else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)) {
                        onSelect(target)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // Let vertical Form/ScrollView gestures pass through unhijacked.
                            guard isDragging || abs(value.translation.width) >= abs(value.translation.height) else {
                                return
                            }
                            isDragging = true
                            let target = levelAtX(value.location.x)
                            if target != displayedEffort {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.14, extraBounce: 0)) {
                                    dragEffort = target
                                }
                                onPreview?(target)
                            }
                        }
                        .onEnded { _ in
                            let committed = dragEffort
                            isDragging = false
                            dragEffort = nil
                            onPreview?(nil)
                            if let committed, committed != effort {
                                onSelect(committed)
                            }
                        }
                )
            }
            .frame(height: trackHeight)
            .sensoryFeedback(.selection, trigger: displayedEffort)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("思考等级滑块")
            .accessibilityValue(displayedEffort.title)
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
                            .font(.caption2.weight(displayedEffort == level ? .semibold : .regular))
                            .foregroundStyle(displayedEffort == level ? palette.textPrimary : palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .accessibilityLabel("思考等级：\(level.title)")
                    .accessibilityAddTraits(displayedEffort == level ? .isSelected : [])
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
