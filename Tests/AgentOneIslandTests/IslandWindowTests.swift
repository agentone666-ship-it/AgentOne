import AppKit
import Combine
import SwiftUI
import Testing
@testable import AgentOneCaptureApp

@MainActor private final class FixtureModel: ObservableObject {
    @Published var expanded = false
}

private struct FixtureView: View {
    @ObservedObject var model: FixtureModel
    var body: some View {
        Button("Toggle") { model.expanded.toggle() }
            .frame(width: model.expanded ? 420 : 240,height: model.expanded ? 560 : 42)
    }
}

@MainActor struct IslandWindowTests {
    @Test func repeatedCollapseAndExpansionChangesRealPanelBounds() async throws {
        let model = FixtureModel()
        let controller = IslandWindowController(content: AnyView(FixtureView(model: model)))
        defer { controller.panel.close() }
        controller.show(expanded: false)
        #expect(controller.panel.appearance?.name == .darkAqua)
        let screen = try #require(NSScreen.main)
        for expanded in [false,true,false,true,false,true] {
            model.expanded = expanded
            controller.position(expanded: expanded)
            try await Task.sleep(for: .milliseconds(100))
            let expected = NSSize(width: expanded ? 420 : 240,height: expanded ? min(560,screen.visibleFrame.height-20) : 42)
            #expect(controller.panel.frame.size == expected)
            #expect(controller.panel.contentView?.frame.size == expected)
            #expect(abs(controller.panel.frame.maxY - (screen.visibleFrame.maxY-6)) < 1)
        }
        controller.panel.orderOut(nil)
        controller.show(expanded: true)
        #expect(controller.panel.isVisible)
        #expect(controller.panel.frame.width == 420)
    }
}
