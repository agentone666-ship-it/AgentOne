import AppKit
import AgentOneCore
import Foundation

/// A CGEvent tap created with `.listenOnly`. Unlike a mutable event tap or an
/// AppKit local monitor, this object has no path that can replace, suppress, or
/// repost the user's keyboard event.
final class PassiveKeyboardEventTap: @unchecked Sendable {
    typealias SignalHandler = @Sendable (ReducedKeyboardSignal, Date) -> Void

    private let signalHandler: SignalHandler
    private var reducer = KeyboardSignalReducer()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(signalHandler: @escaping SignalHandler) {
        self.signalHandler = signalHandler
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: opaqueSelf
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        reducer = KeyboardSignalReducer()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<PassiveKeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        monitor.consume(event)
        return Unmanaged.passUnretained(event)
    }

    private func consume(_ event: CGEvent) {
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let kind: KeyboardObservation.Kind

        switch keyCode {
        case 36, 76:
            kind = .returnKey
        case 51, 117:
            kind = .deletionKey
        default:
            let modifierPattern = Self.modifierPattern(event.flags)
            if modifierPattern.isEmpty {
                kind = .textInput(estimatedCharacterCount: 1)
            } else {
                kind = .shortcut(modifierPattern: modifierPattern)
            }
        }

        let timestamp = Date()
        let observation = KeyboardObservation(
            timestamp: timestamp,
            kind: kind,
            isAutorepeat: isAutorepeat
        )
        for signal in reducer.consume(observation) {
            signalHandler(signal, timestamp)
        }
    }

    private static func modifierPattern(_ flags: CGEventFlags) -> String {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskControl) { names.append("control") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskShift) { names.append("shift") }
        return names.joined(separator: "+")
    }
}
