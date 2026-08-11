import AppKit
import SwiftUI

@main
struct AgentOneDesktopApp: App {
    @StateObject private var runtime = AgentOneRuntime()

    var body: some Scene {
        WindowGroup("AgentOne", id: "main") {
            AgentOneShellView(
                model: runtime.shellModel,
                forceOnboarding: DocumentationDemo.isEnabled ? false : nil,
                onReady: { runtime.start() }
            )
                .onReceive(NotificationCenter.default.publisher(for: .agentOneRequestedOpenMainWindow)) { _ in
                    runtime.shellModel.selection = .replay
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                .onReceive(NotificationCenter.default.publisher(for: .agentOneRequestedReturnToTask)) { _ in
                    runtime.shellModel.selection = .now
                    runtime.markCurrentDetourAsDistraction()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                .onReceive(NotificationCenter.default.publisher(for: .agentOneReportedIntentionChange)) { _ in
                    // “我换目标了” is a high-value correction signal: the apparent detour is
                    // intentional, so learn from it without interrupting or raising the main window.
                    runtime.markCurrentDetourAsRelated()
                }
                .onReceive(NotificationCenter.default.publisher(for: .agentOneRequestedToggleChat)) { _ in
                    runtime.companion.toggleChat()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.titleBar)

        MenuBarExtra("AgentOne", systemImage: "sparkles") {
            AgentOneMenuBarRoot(runtime: runtime)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct AgentOneMenuBarRoot: View {
    @ObservedObject var runtime: AgentOneRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AgentOneMenuBarView(
            shellModel: runtime.shellModel,
            companion: runtime.companion,
            openMainWindow: {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        )
    }
}
