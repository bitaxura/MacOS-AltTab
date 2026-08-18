import Foundation
import AppKit

// Reads raw per-finger touch frames from the trackpad and turns them into
// gestures. Direct 1-to-1 physical spatial 2D mapping for window switching
// and ultra-responsive 3-finger middle click taps.
final class GestureEngine {
    static let shared = GestureEngine()

    private var device: MTDeviceRef?
    private let debug = ProcessInfo.processInfo.environment["TPG_DEBUG"] != nil

    // Touch tracking state
    private var lastCount: Int32 = 0
    private var sessionPeakFingers: Int32 = 0
    private var sessionStartTime: CFTimeInterval = 0

    // 3-finger calibrated state
    private var threeFingerStartTime: CFTimeInterval = 0
    private var threeFingerOriginX: Float = 0
    private var threeFingerOriginY: Float = 0
    private var threeFingerMaxDrift: Float = 0
    private var hasCalibratedThreeFingers = false

    // Switcher state
    private var switcherActive = false
    private var gestureOriginX: Float = 0
    private var gestureOriginY: Float = 0
    private var gestureBaseRow: Int = 0
    private var gestureBaseCol: Int = 0

    // --- Tunables ---------------------------------------------------------
    /// Distance fingers must move from touchdown to activate the switcher.
    private let swipeActivationThreshold: Float = 0.035
    /// Maximum finger drift permitted during a 3-finger tap for middle click.
    private let tapMaxDrift: Float = 0.055
    /// Maximum contact duration for a 3-finger tap (in seconds).
    private let tapMaxDuration: CFTimeInterval = 0.40
    /// Horizontal trackpad distance per card column in 2D spatial mapping.
    private let switchStepDistanceX: Float = 0.075
    /// Vertical trackpad distance per card row in 2D spatial mapping.
    private let switchStepDistanceY: Float = 0.085
    // ------------------------------------------------------------------

    func start() {
        guard let dev = MTDeviceCreateDefault() else {
            NSLog("TrackpadGestures: could not create multitouch device — is a trackpad present?")
            return
        }
        device = dev
        MTRegisterContactFrameCallback(dev, multitouchTrampoline)
        MTDeviceStart(dev, 0)
    }

    func stop() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, multitouchTrampoline)
        MTDeviceStop(dev)
    }

    /// Pure primitive state check; safe to call from background multitouch thread without instantiating UI.
    var isGestureInProgress: Bool {
        lastCount > 0 || sessionPeakFingers > 0 || switcherActive
    }

    fileprivate func handleFrame(_ touches: [MTTouch], count: Int32) {
        let now = CACurrentMediaTime()

        if debug {
            NSLog("TPG frame: count=\(count) states=\(touches.map { $0.state })")
        }

        if count > 0 {
            sessionPeakFingers = max(sessionPeakFingers, count)
        }

        // Lock out 3-finger gestures if 4 or more fingers touch the pad
        if count >= 4 || sessionPeakFingers >= 4 {
            if switcherActive {
                SwitcherPanel.shared.dismiss()
                switcherActive = false
            }
        }

        // Session boundaries
        if count != lastCount {
            if lastCount == 0 && count > 0 {
                sessionStartTime = now
                sessionPeakFingers = count
                hasCalibratedThreeFingers = false
                threeFingerMaxDrift = 0
                switcherActive = SwitcherPanel.shared.isVisible
                if switcherActive { gestureBaseRow = 0; gestureBaseCol = 0 }
                if count == 3 { calibrateThreeFingerOrigin(touches: touches, now: now) }
            } else if count == 0 && lastCount > 0 {
                endSession(now: now)
            }
            lastCount = count
        }

        // Process 3-finger tracking
        if count == 3 && sessionPeakFingers == 3 {
            trackThreeFinger(touches: touches, now: now)
        }
    }

    private func calibrateThreeFingerOrigin(touches: [MTTouch], now: CFTimeInterval) {
        let (avgX, avgY) = averagePosition(touches)
        threeFingerStartTime = now
        threeFingerOriginX = avgX
        threeFingerOriginY = avgY
        threeFingerMaxDrift = 0
        hasCalibratedThreeFingers = true
    }

    private func endSession(now: CFTimeInterval) {
        if switcherActive {
            SwitcherPanel.shared.commit()
            switcherActive = false
            sessionPeakFingers = 0
            hasCalibratedThreeFingers = false
            return
        }

        let duration = now - (hasCalibratedThreeFingers ? threeFingerStartTime : sessionStartTime)
        let isTap = sessionPeakFingers == 3 && duration <= tapMaxDuration && threeFingerMaxDrift <= tapMaxDrift
        sessionPeakFingers = 0
        hasCalibratedThreeFingers = false

        if isTap {
            Self.postMiddleClick()
        }
    }

    private func trackThreeFinger(touches: [MTTouch], now: CFTimeInterval) {
        if !hasCalibratedThreeFingers {
            calibrateThreeFingerOrigin(touches: touches, now: now)
        }

        let (avgX, avgY) = averagePosition(touches)
        let dx = avgX - threeFingerOriginX
        let dy = avgY - threeFingerOriginY
        let distance = hypot(dx, dy)
        threeFingerMaxDrift = max(threeFingerMaxDrift, distance)

        if !switcherActive {
            // Activate switcher once movement crosses activation threshold
            if distance >= swipeActivationThreshold {
                switcherActive = true
                let initialDirection = dx >= 0 ? 1 : -1
                SwitcherPanel.shared.show(initialDirection: initialDirection)

                gestureOriginX = avgX
                gestureOriginY = avgY
                let initialIndex = (initialDirection > 0 && SwitcherPanel.shared.windows.count > 1) ? 1 : 0
                let cols = max(1, SwitcherPanel.shared.gridColumns)
                gestureBaseRow = initialIndex / cols
                gestureBaseCol = initialIndex % cols
            }
            return
        }

        // Direct 1-to-1 Spatial 2D Physical Tracking:
        let relX = avgX - gestureOriginX
        let relY = avgY - gestureOriginY

        let colOffset = Int(round(relX / switchStepDistanceX))
        // Trackpad Multitouch: moving fingers UP increases avg.y (towards screen), relY > 0 -> rowOffset is negative (towards top row 0)
        // Moving fingers DOWN decreases avg.y (towards wrist), relY < 0 -> rowOffset is positive (towards bottom row)
        let rowOffset = -Int(round(relY / switchStepDistanceY))

        SwitcherPanel.shared.selectGrid(row: gestureBaseRow + rowOffset, col: gestureBaseCol + colOffset)
    }

    private func averagePosition(_ touches: [MTTouch]) -> (x: Float, y: Float) {
        guard !touches.isEmpty else { return (threeFingerOriginX, threeFingerOriginY) }
        let sx = touches.reduce(0) { $0 + $1.normalized.position.x }
        let sy = touches.reduce(0) { $0 + $1.normalized.position.y }
        let n = Float(touches.count)
        return (sx / n, sy / n)
    }

    // MARK: - Three-finger tap → middle click

    static func postMiddleClick() {
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
}

// MARK: - C trampoline
private func multitouchTrampoline(device: MTDeviceRef?, data: UnsafeMutablePointer<MTTouch>?, numFingers: Int32, timestamp: Double, frame: Int32) -> Int32 {
    guard let data = data, numFingers > 0 else {
        if GestureEngine.shared.isGestureInProgress {
            DispatchQueue.main.async {
                GestureEngine.shared.handleFrame([], count: 0)
            }
        }
        return 0
    }

    if numFingers < 3 && !GestureEngine.shared.isGestureInProgress {
        return 0
    }

    let buffer = UnsafeBufferPointer(start: data, count: Int(numFingers))
    let touches = Array(buffer)
    DispatchQueue.main.async {
        GestureEngine.shared.handleFrame(touches, count: numFingers)
    }
    return 0
}
