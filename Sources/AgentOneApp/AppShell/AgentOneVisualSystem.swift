import SwiftUI

// MARK: - Palette

enum AgentOnePalette {
    // Base
    static let background = Color(red: 0.028, green: 0.033, blue: 0.058)

    // Layered surfaces (replaces ad-hoc white opacities)
    static let surface1 = Color(red: 0.066, green: 0.075, blue: 0.115)
    static let surface2 = Color(red: 0.089, green: 0.100, blue: 0.148)
    static let surface3 = Color(red: 0.112, green: 0.124, blue: 0.176)

    // Strokes & text
    static let border = Color.white.opacity(0.09)
    static let borderBright = Color.white.opacity(0.16)
    static let separator = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    // Accents (jewel tones)
    static let blue = Color(red: 0.47, green: 0.69, blue: 1.0)
    static let violet = Color(red: 0.73, green: 0.56, blue: 1.0)
    static let mint = Color(red: 0.44, green: 0.92, blue: 0.79)
    static let amber = Color(red: 1.0, green: 0.79, blue: 0.45)

    // Back-compat aliases for call sites not yet migrated
    static let elevated = surface1
    static let elevatedSoft = surface2
}

// MARK: - Type scale (minimum 11pt)

enum AgentOneType {
    static let display = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let callout = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
}

// MARK: - Metrics

enum AgentOneMetric {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 20
    static let spacingXXL: CGFloat = 28

    static let radiusSmall: CGFloat = 10
    static let radiusCard: CGFloat = 16
    static let radiusHero: CGFloat = 20
}

// MARK: - Card

struct AgentOneCardModifier: ViewModifier {
    var padding: CGFloat = AgentOneMetric.spacingXL

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                    .fill(AgentOnePalette.surface1.opacity(0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [AgentOnePalette.borderBright, AgentOnePalette.separator],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
            )
    }
}

extension View {
    func agentOneCard(padding: CGFloat = AgentOneMetric.spacingXL) -> some View {
        modifier(AgentOneCardModifier(padding: padding))
    }
}

// MARK: - Pill

struct AgentOnePill: View {
    let title: String
    var symbol: String?
    var tint: Color = AgentOnePalette.blue

    var body: some View {
        HStack(spacing: AgentOneMetric.spacingXS) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .font(AgentOneType.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay { Capsule().stroke(tint.opacity(0.26), lineWidth: 1) }
    }
}

// MARK: - Section heading

struct SectionHeading: View {
    let eyebrow: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(AgentOnePalette.blue)
            Text(title)
                .font(AgentOneType.display)
                .foregroundStyle(AgentOnePalette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(AgentOneType.body)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Memory glow being (adapter over the unified renderer)

/// “记忆微光体”：不是拟人动物，而是一种由意识核、记忆粒子和上下文轨道组成的数字生命。
/// 统一委托 `DigitalLifeView` 渲染，全 App 形象一致；`AgentMood` 仅映射到生命状态。
struct MemoryGlowBeing: View {
    var mood: AgentMood
    var size: CGFloat = 120
    var isActive = true

    private var lifeState: DigitalLifeState {
        switch mood {
        case .observing, .focused: return .focused
        case .curious: return .curious
        case .resting: return .resting
        case .delighted: return .celebrating
        }
    }

    var body: some View {
        DigitalLifeView(state: lifeState, size: size)
            .opacity(isActive ? 1 : 0.55)
            .saturation(isActive ? 1 : 0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("数字生命，\(mood.title)")
    }
}

// MARK: - Ambient background

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            AgentOnePalette.background
            RadialGradient(
                colors: [AgentOnePalette.violet.opacity(0.16), .clear],
                center: UnitPoint(x: 0.85, y: 0.02),
                startRadius: 0,
                endRadius: 560
            )
            RadialGradient(
                colors: [AgentOnePalette.blue.opacity(0.11), .clear],
                center: UnitPoint(x: 0.22, y: 0.92),
                startRadius: 0,
                endRadius: 640
            )
            RadialGradient(
                colors: [AgentOnePalette.mint.opacity(0.05), .clear],
                center: UnitPoint(x: 0.55, y: 0.45),
                startRadius: 0,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}
