import SwiftUI

/// A living style guide for development, design review, and SwiftUI previews.
struct DigitalLifeShowcase: View {
    private let states: [DigitalLifeState] = [
        .focused,
        .curious,
        .thinking,
        .distraction(level: 1),
        .distraction(level: 2),
        .distraction(level: 3),
        .distraction(level: 4),
        .celebrating,
        .resting,
        .energySaver,
        .concealingSurprise
    ]

    @State private var selectedState: DigitalLifeState = .curious
    @StateObject private var controller = DigitalLifeController(
        state: .curious,
        prompt: .curiosity("这个视频是在帮你找论文案例吗？"),
        currentTaskName: "论文方法章节"
    )
    @StateObject private var chat = AgentChatController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("记忆微光体")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("意识核 · 记忆轨道 · 可被共同经历塑造的数字轮廓")
                        .foregroundStyle(.secondary)
                }

                stateGrid

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("浮窗交互")
                        .font(.title2.bold())

                    HStack(spacing: 10) {
                        demoButton("好奇") {
                            controller.becomeCurious(about: "这个页面和刚才的写作有关吗？")
                        }
                        demoButton("提醒 +1") {
                            controller.escalateDistractionReminder()
                        }
                        demoButton("庆祝") { controller.celebrate() }
                        demoButton("休息") { controller.rest() }
                        demoButton("藏惊喜") { controller.concealSurprise() }
                        demoButton("安静") { controller.settle() }
                    }

                    DigitalLifeFloatingContent(controller: controller, chat: chat)
                        .frame(maxWidth: .infinity, minHeight: 190, alignment: .trailing)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.06, green: 0.07, blue: 0.12),
                                    Color(red: 0.12, green: 0.13, blue: 0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                }
            }
            .padding(28)
        }
        .frame(minWidth: 860, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var stateGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 14)], spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Button {
                    selectedState = state
                    controller.transition(to: state)
                } label: {
                    VStack(spacing: 4) {
                        DigitalLifeView(state: state, size: 116)
                        Text(state.displayName)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.primary.opacity(selectedState == state ? 0.08 : 0.035))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(
                                        Color.accentColor.opacity(selectedState == state ? 0.5 : 0),
                                        lineWidth: 1
                                    )
                            }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func demoButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

struct DigitalLifeShowcase_Previews: PreviewProvider {
    static var previews: some View {
        DigitalLifeShowcase()
            .previewDisplayName("Digital Life System")
    }
}
