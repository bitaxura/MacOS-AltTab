import Foundation
import AppKit
import CoreAudio

// All the actual "do the thing" code. Kept separate from GestureEngine so the
// gesture-detection logic and the action-posting logic don't get tangled.
struct ActionPoster {

    // MARK: - Three-finger tap → middle click

    static func postMiddleClick() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                postMiddleClick()
            }
            return
        }

        let loc = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: loc.x, y: screenHeight - loc.y) // flip to CG's top-left origin

        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center),
            let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center)
        else { return }

        down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 2)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Legacy App Switcher Helpers

    private static let commandKeyCode: CGKeyCode = 0x37
    private static let tabKeyCode: CGKeyCode = 0x30
    private static var commandHeld = false

    static func beginAppSwitcher(forward: Bool) {
        postKey(commandKeyCode, down: true, flags: [])
        commandHeld = true
        postKey(tabKeyCode, down: true, flags: forward ? [.maskCommand] : [.maskCommand, .maskShift])
        postKey(tabKeyCode, down: false, flags: forward ? [.maskCommand] : [.maskCommand, .maskShift])
    }

    static func stepAppSwitcher(forward: Bool) {
        guard commandHeld else { return }
        postKey(tabKeyCode, down: true, flags: forward ? [.maskCommand] : [.maskCommand, .maskShift])
        postKey(tabKeyCode, down: false, flags: forward ? [.maskCommand] : [.maskCommand, .maskShift])
    }

    static func endAppSwitcher() {
        guard commandHeld else { return }
        postKey(commandKeyCode, down: false, flags: [])
        commandHeld = false
    }

    private static func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
