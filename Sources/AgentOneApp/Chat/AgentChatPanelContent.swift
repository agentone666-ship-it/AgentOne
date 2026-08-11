import SwiftUI

struct AgentChatPanelContent: View {
    @ObservedObject var chat: AgentChatController

    @FocusState private var inputFocused: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            conversation
            composer
        }
        .frame(width: 364, height: 450)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AgentOnePalette.violet.opacity(0.11),
                                    AgentOnePalette.mint.opacity(0.045),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(isHovered ? AgentOnePalette.borderBright : AgentOnePalette.border, lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .onHover { isHovered = $0 }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                inputFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AgentOnePalette.violet.opacity(0.16))
                Circle()
                    .fill(AgentOnePalette.violet)
                    .frame(width: 8, height: 8)
                    .shadow(color: AgentOnePalette.violet.opacity(0.8), radius: 5)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.isThinking ? "正在想……" : "和我说说")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(chat.contextStatusText)
                    .font(AgentOneType.caption)
                    .foregroundStyle(chat.canIncludeCurrentContext ? AgentOnePalette.textSecondary : AgentOnePalette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                chat.clearConversation()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AgentOnePalette.textSecondary)
            .help("开始一段新对话")

            Button {
                chat.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AgentOnePalette.textSecondary)
            .accessibilityLabel("关闭对话")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if chat.isThinking {
                        thinkingBubble
                            .id("agent-thinking")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
            .onChange(of: chat.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chat.isThinking) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageBubble(_ message: AgentChatMessage) -> some View {
        VStack(
            alignment: message.role == .user ? .trailing : .leading,
            spacing: 4
        ) {
            Text(message.content)
                .font(AgentOneType.body)
                .foregroundStyle(message.role == .user ? .white : AgentOnePalette.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            message.role == .user
                                ? AgentOnePalette.blue.opacity(0.92)
                                : AgentOnePalette.surface2
                        )
                }

            if let contextLabel = message.contextLabel {
                Label("引用了 \(contextLabel)", systemImage: "scope")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(message.role == .user ? .leading : .trailing, 42)
    }

    private var thinkingBubble: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AgentOnePalette.violet.opacity(0.72))
                    .frame(width: 5, height: 5)
                    .scaleEffect(chat.isThinking ? 1 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.14),
                        value: chat.isThinking
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(AgentOnePalette.surface2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 180)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if chat.canIncludeCurrentContext {
                Toggle(isOn: $chat.includesCurrentContext) {
                    Label("引用此刻", systemImage: "scope")
                        .font(AgentOneType.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("想问我什么？", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AgentOneType.body)
                    .foregroundStyle(AgentOnePalette.textPrimary)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit {
                        chat.submitDraft()
                    }
                    .disabled(chat.isThinking)

                if chat.isThinking {
                    Button {
                        chat.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(AgentOnePalette.surface2))
                    .help("停止思考")
                } else {
                    Button {
                        chat.submitDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle().fill(
                            chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AgentOnePalette.surface3
                                : AgentOnePalette.blue
                        )
                    )
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("发送（⌘↩）")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AgentOnePalette.surface1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AgentOnePalette.separator, lineWidth: 0.7)
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if chat.isThinking {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("agent-thinking", anchor: .bottom)
                }
            } else if let last = chat.messages.last {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
