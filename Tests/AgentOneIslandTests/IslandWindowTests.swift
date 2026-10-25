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
        Button("Toggle") { model.expanded.toggle() }.frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}

@MainActor @Suite(.serialized) struct IslandWindowTests {
    @Test func repeatedCollapseAndExpansionChangesRealPanelBounds() async throws {
        let model = FixtureModel()
        let controller = IslandWindowController(content: AnyView(FixtureView(model: model)))
        defer { controller.panel.close() }
        controller.show(expanded: false)
        #expect(controller.panel.appearance?.name == .darkAqua)
        #expect(controller.panel.initialFirstResponder === controller.panel.contentView)
        #expect(!(controller.panel.firstResponder is NSTextView))
        let screen = try #require(IslandWindowController.targetScreen)
        let geometry = IslandGeometry(screen: screen)
        for expanded in [false,true,false,true,false,true] {
            model.expanded = expanded
            controller.position(expanded: expanded)
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.panel.frame == geometry.window(expanded: expanded))
            #expect(controller.panel.contentView?.frame.size == controller.panel.frame.size)
        }
        controller.panel.orderOut(nil)
        controller.show(expanded: true)
        #expect(controller.panel.isVisible)
        #expect(controller.panel.frame.width == 480)
    }

    @Test func hardwareNotchAndExternalDisplayGeometry() {
        let notch = IslandGeometry(frame: NSRect(x: -1512,y: 900,width: 1512,height: 982),notchWidth: 180,notchHeight: 32)
        let camera = NSPoint(x: notch.frame.midX,y: notch.frame.maxY-2)
        #expect(notch.activationRect.contains(camera))
        #expect(!notch.activationRect.contains(NSPoint(x: notch.frame.midX+300,y: camera.y)))
        #expect(notch.window(expanded: false).maxY == notch.frame.maxY)
        #expect(notch.window(expanded: true).maxY == notch.frame.maxY)
        #expect(notch.compactSize.width == 284)
        let external = IslandGeometry(frame: NSRect(x: 0,y: 0,width: 1920,height: 1055))
        #expect(!external.isNotched)
        #expect(external.window(expanded: false).maxY == 1048)
        #expect(external.window(expanded: false).height == 38)
    }

    @Test func hoverDebouncesEntryAndCancelsPendingCloseOnReentry() {
        var state = IslandHoverState()
        #expect(state.update(inside: true,expanded: false,protected: false,now: 0) == nil)
        #expect(state.update(inside: false,expanded: false,protected: false,now: 0.1) == nil)
        #expect(state.update(inside: true,expanded: false,protected: false,now: 1) == nil)
        #expect(state.update(inside: true,expanded: false,protected: false,now: 1.17) == true)
        #expect(state.update(inside: false,expanded: true,protected: false,now: 2) == nil)
        #expect(state.update(inside: true,expanded: true,protected: false,now: 2.5) == nil)
        #expect(state.update(inside: false,expanded: true,protected: false,now: 3) == nil)
        #expect(state.update(inside: false,expanded: true,protected: false,now: 3.61) == false)
    }

    @Test func pinEditingAndModalProtectionRestartExitDelay() {
        var state = IslandHoverState()
        #expect(state.update(inside: false,expanded: true,protected: false,now: 0) == nil)
        #expect(state.update(inside: false,expanded: true,protected: true,now: 1) == nil)
        #expect(state.update(inside: false,expanded: true,protected: true,now: 60) == nil)
        #expect(state.update(inside: false,expanded: true,protected: false,now: 61) == nil)
        #expect(state.update(inside: false,expanded: true,protected: false,now: 61.7) == false)
    }

    @Test func hoverSamplesResizeTheRealPanelWithoutClicking() async throws {
        let model = FixtureModel()
        let controller = IslandWindowController(content: AnyView(FixtureView(model: model)))
        defer { controller.stopHoverMonitoring(); controller.panel.close() }
        controller.onExpansionRequested = { model.expanded = $0 }
        controller.show(expanded: false)
        let screen = try #require(IslandWindowController.targetScreen)
        let geometry = IslandGeometry(screen: screen)
        let top = NSPoint(x: geometry.frame.midX,y: geometry.top-2)
        let outside = NSPoint(x: geometry.frame.minX+10,y: geometry.frame.minY+10)
        let now = ProcessInfo.processInfo.systemUptime + 2
        controller.samplePointer(at: top,now: now)
        controller.samplePointer(at: top,now: now+0.2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.expanded)
        #expect(controller.panel.frame == geometry.window(expanded: true))
        // Moving from the camera cutout down into the controls must keep it open.
        let controls = NSPoint(x: geometry.frame.midX,y: geometry.top-180)
        controller.samplePointer(at: controls,now: now+1)
        #expect(controller.expanded)
        controller.pinned = true
        controller.samplePointer(at: outside,now: now+2)
        controller.samplePointer(at: outside,now: now+3)
        #expect(controller.expanded)
        controller.pinned = false
        controller.samplePointer(at: outside,now: now+4)
        controller.samplePointer(at: outside,now: now+4.7)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.expanded)
        #expect(controller.panel.frame == geometry.window(expanded: false))
    }
}
