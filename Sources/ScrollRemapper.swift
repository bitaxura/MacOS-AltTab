import Cocoa

// macOS only has one global "natural scrolling" checkbox that applies to
// every device. This intercepts scroll events and inverts mouse scroll and
// trackpad scroll independently, so you can have each set the way you want
// regardless of what the system checkbox says.
final class ScrollRemapper {
    static let shared = ScrollRemapper()

    // Flip these to taste. true = reverse what the device naturally reports.
    var invertMouseScroll = true
    var invertTrackpadScroll = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollEventCallback,
            userInfo: nil
        ) else {
            NSLog("TrackpadGestures: failed to create scroll event tap — check Input Monitoring permission")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handleCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .scrollWheel {
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let shouldInvert = isContinuous ? invertTrackpadScroll : invertMouseScroll
            if shouldInvert {
                let fields: [CGEventField] = [
                    .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                    .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2
                ]
                for field in fields {
                    let value = event.getIntegerValueField(field)
                    if value != 0 {
                        event.setIntegerValueField(field, value: -value)
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}

private func scrollEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    ScrollRemapper.shared.handleCallback(type: type, event: event)
}
