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
            (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
        )

        // Try HID event tap first to intercept Cmd+Tab before macOS Dock, with fallback to Session tap
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyCallback,
            userInfo: nil
        )

        if tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: keyCallback,
                userInfo: nil
            )
        }

        guard let validTap = tap else {
            NSLog("TrackpadGestures: failed to create key interceptor — check Input Monitoring permission")
            return
        }

        eventTap = validTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, validTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: validTap, enable: true)
    }

    fileprivate func handleCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let commandActive = flags.contains(.maskCommand)

        switch type {
        case .flagsChanged:
            let wasCommandDown = commandDown
            if wasCommandDown && !commandActive {
                if SwitcherController.shared.isVisible {
                    SwitcherController.shared.commit()
                }
            }
            commandDown = commandActive
            return Unmanaged.passRetained(event)

        case .keyDown:
            // Intercept Cmd+Tab (KeyCode 48)
            if commandActive && keyCode == 48 {
                if flags.contains(.maskShift) {
                    SwitcherController.shared.step(direction: -1)
                } else {
                    SwitcherController.shared.step(direction: 1)
                }
                return nil
            }

            if SwitcherController.shared.isVisible {
                if commandActive {
                    if keyCode == 13 { // Cmd + W: Close selected window
                        SwitcherController.shared.closeSelectedWindow()
                        return nil
                    }
                    if keyCode == 12 { // Cmd + Q: Quit selected app
                        SwitcherController.shared.quitSelectedApp()
                        return nil
                    }
                }

                switch keyCode {
                case 123: // Left Arrow
                    SwitcherController.shared.stepGrid(rowDelta: 0, colDelta: -1)
                    return nil
                case 124: // Right Arrow
                    SwitcherController.shared.stepGrid(rowDelta: 0, colDelta: 1)
                    return nil
                case 126: // Up Arrow
                    SwitcherController.shared.stepGrid(rowDelta: -1, colDelta: 0)
                    return nil
                case 125: // Down Arrow
                    SwitcherController.shared.stepGrid(rowDelta: 1, colDelta: 0)
                    return nil
                case 53: // Escape
                    SwitcherController.shared.cancel()
                    return nil
                case 36, 49: // Return or Space
                    SwitcherController.shared.commit()
                    return nil
                default:
                    break
                }
            }

            return Unmanaged.passRetained(event)

        case .keyUp:
            if keyCode == 0x37 || keyCode == 0x36 { // Left or Right Command
                commandDown = false
                if SwitcherController.shared.isVisible {
                    SwitcherController.shared.commit()
                }
            }
            return Unmanaged.passRetained(event)

        default:
            return Unmanaged.passRetained(event)
        }
    }
}

private func keyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    KeyInterceptor.shared.handleCallback(proxy: proxy, type: type, event: event)
}
