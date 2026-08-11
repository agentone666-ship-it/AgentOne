import SwiftUI

struct DigitalLifePanelPlacement: Equatable, Sendable {
    enum Horizontal: Equatable, Sendable {
        /// The prompt grows to the left of the life.
        case promptLeading
        /// The prompt grows to the right of the life.
        case promptTrailing
    }

    enum Vertical: Equatable, Sendable {
        /// The panel grows upward while the life keeps its bottom edge fixed.
        case bottomAnchored
        /// The panel grows downward while the life keeps its top edge fixed.
        case topAnchored
    }

    var horizontal: Horizontal = .promptLeading
    var vertical: Vertical = .bottomAnchored

    var alignment: Alignment {
        switch (horizontal, vertical) {
        case (.promptLeading, .bottomAnchored): .bottomTrailing
        case (.promptLeading, .topAnchored): .topTrailing
        case (.promptTrailing, .bottomAnchored): .bottomLeading
        case (.promptTrailing, .topAnchored): .topLeading
        }
    }

    var unitPoint: UnitPoint {
        switch (horizontal, vertical) {
        case (.promptLeading, .bottomAnchored): .bottomTrailing
        case (.promptLeading, .topAnchored): .topTrailing
        case (.promptTrailing, .bottomAnchored): .bottomLeading
        case (.promptTrailing, .topAnchored): .topLeading
        }
    }
}

/// Window-agnostic content for the always-on-top desktop companion panel.
/// The app shell decides the `NSPanel` behavior; this view owns the creature and its prompt.
struct DigitalLifeFloatingContent: View {
    @ObservedObject var controller: DigitalLifeController
    @ObservedObject var chat: AgentChatController
    var promptPlacement = DigitalLifePanelPlacement()
    var onAction: (DigitalLifeAction) -> Void = { _ in }
    var onPromptVisibilityChange: (Bool) -> Void = { _ in }
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}

    @State private var isPromptHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: promptPlacement.vertical == .bottomAnchored ? .bottom : .top, spacing: 4) {
            if promptPlacement.horizontal == .promptLeading {
                expandedView
            }

            lifeView

            if promptPlacement.horizontal == .promptTrailing {
                expandedView
            }
        }
        .padding(10)
        // The panel changes width around this bottom-trailing anchor. The life itself therefore
        // never jumps when a thought bubble appears or disappears.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: promptPlacement.alignment)
        .animation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.78), value: controller.prompt)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: chat.isOpen)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: controller.state)
        .onChange(of: controller.prompt != nil) { _, isVisible in
            onPromptVisibilityChange(isVisible)
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        if chat.isOpen {
            AgentChatPanelContent(chat: chat)
                .transition(promptTransition)
        } else if let prompt = controller.prompt {
            promptCard(prompt)
                .transition(promptTransition)
        }
    }

    private var promptTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .scale(scale: 0.92, anchor: promptPlacement.unitPoint).combined(with: .opacity),
            removal: .scale(scale: 0.96, anchor: promptPlacement.unitPoint).combined(with: .opacity)
        )
    }

    private var lifeView: some View {
        DigitalLifeView(
            state: controller.state,
            size: 126,
            interactionRevision: controller.interactionRevision
        ) { action in
            controller.registerTouch()
            onAction(action)
        }
        .padding(4)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
        .help("点击和我聊天，拖动我到桌面的任何位置")
    }

    private func promptCard(_ prompt: DigitalLifePrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(prompt.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let detail = prompt.detail {
                            Text(detail)
                                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .scrollIndicators(.visible)

                Button {
                    controller.clearPrompt()
                    onAction(.dismissPrompt)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("关闭")
            }

            HStack(spacing: 7) {
                if let primary = prompt.primaryActionTitle {
                    Button(primary) {
                        performPrimaryAction(for: prompt)
                    }
                    .buttonStyle(DigitalLifePrimaryButtonStyle())
                }

                if let secondary = prompt.secondaryActionTitle {
                    Button(secondary) {
                        performSecondaryAction(for: prompt)
                    }
                    .buttonStyle(DigitalLifeSecondaryButtonStyle())
                }
            }
        }
        .padding(14)
        .frame(width: 258, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(isPromptHovered ? 0.24 : 0.12), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        }
        .onHover { isPromptHovered = $0 }
    }

    private func performPrimaryAction(for prompt: DigitalLifePrompt) {
        controller.clearPrompt()
        switch prompt.kind {
        case .curiosity:
            onAction(.answerCuriosity)
        case .returnToTask:
            onAction(.returnToTask)
        case .reflection:
            onAction(.openJournal)
        case .energy:
            onAction(.touched)
        }
    }

    private func performSecondaryAction(for prompt: DigitalLifePrompt) {
        controller.clearPrompt()
        switch prompt.kind {
        case .returnToTask:
            onAction(.changeIntention)
        default:
            onAction(.dismissPrompt)
        }
    }
}

private struct DigitalLifePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(red: 0.44, green: 0.42, blue: 0.98).opacity(configuration.isPressed ? 0.72 : 0.94))
            )
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
    }
}

private struct DigitalLifeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.1 : 0.055)))
    }
}
