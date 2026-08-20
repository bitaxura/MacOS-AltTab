import Foundation
import AppKit
import CoreGraphics

final class KeyInterceptor {
    static let shared = KeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var commandDown = false

    func start() {
        let mask = CGEventMask(
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        )

        // Try HID event tap first to intercept Cmd+Tab before macOS Dock, with fallback to Session tap
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: keyCallback, userInfo: nil)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: keyCallback, userInfo: nil)

        guard let validTap = tap else {
            NSLog("TrackpadGestures: failed to create key/event interceptor — check Input Monitoring permission")
            return
        }

        eventTap = validTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, validTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: validTap, enable: true)
    }

    fileprivate func handleCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if type == .scrollWheel {
            if GestureEngine.shared.shouldSuppressScroll {
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)

        switch type {
        case .flagsChanged:
            if commandDown && !cmd && SwitcherPanel.shared.isVisible {
                SwitcherPanel.shared.commit()
            }
            commandDown = cmd
        case .keyDown:
            // Intercept Cmd+Tab (KeyCode 48)
            if cmd && code == 48 {
                SwitcherPanel.shared.step(direction: flags.contains(.maskShift) ? -1 : 1)
                return nil
            }
            if SwitcherPanel.shared.isVisible {
                switch code {
                case 13 where cmd: // Cmd + W: Close selected window
                    SwitcherPanel.shared.closeSelectedWindow()
                case 12 where cmd: // Cmd + Q: Quit selected app
                    SwitcherPanel.shared.quitSelectedApp()
                case 123: // Left Arrow
                    SwitcherPanel.shared.stepGrid(rowDelta: 0, colDelta: -1)
                case 124: // Right Arrow
                    SwitcherPanel.shared.stepGrid(rowDelta: 0, colDelta: 1)
                case 126: // Up Arrow
                    SwitcherPanel.shared.stepGrid(rowDelta: -1, colDelta: 0)
                case 125: // Down Arrow
                    SwitcherPanel.shared.stepGrid(rowDelta: 1, colDelta: 0)
                case 53: // Escape
                    SwitcherPanel.shared.dismiss()
                case 36, 49: // Return or Space
                    SwitcherPanel.shared.commit()
                default:
                    return Unmanaged.passRetained(event)
                }
                return nil
            }
        case .keyUp where (code == 0x37 || code == 0x36): // Left or Right Command
            commandDown = false
            if SwitcherPanel.shared.isVisible {
                SwitcherPanel.shared.commit()
            }
        default:
            break
        }
        return Unmanaged.passRetained(event)
    }
}

private func keyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    KeyInterceptor.shared.handleCallback(type: type, event: event)
}
