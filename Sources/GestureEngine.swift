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
    private var hasActivatedSwipe = false
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
        guard let device = MTDeviceCreateDefault() else {
            NSLog("TrackpadGestures: could not create multitouch device — is a trackpad present?")
            return
        }
        self.device = device
        MTRegisterContactFrameCallback(device, multitouchTrampoline)
        MTDeviceStart(device, 0)
    }

    func stop() {
        guard let device = device else { return }
        MTUnregisterContactFrameCallback(device, multitouchTrampoline)
        MTDeviceStop(device)
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
                SwitcherController.shared.cancel()
                switcherActive = false
            }
            hasActivatedSwipe = false
        }

        // Session boundaries
        if count != lastCount {
            if lastCount == 0 && count > 0 {
                beginSession(touches: touches, now: now, count: count)
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

    private func beginSession(touches: [MTTouch], now: CFTimeInterval, count: Int32) {
        sessionStartTime = now
        sessionPeakFingers = count
        hasCalibratedThreeFingers = false
        threeFingerMaxDrift = 0
        hasActivatedSwipe = false

        if count == 3 {
            calibrateThreeFingerOrigin(touches: touches, now: now)
        }

        if SwitcherController.shared.isVisible {
            switcherActive = true
            hasActivatedSwipe = true
            gestureBaseRow = 0
            gestureBaseCol = 0
        } else {
            switcherActive = false
        }
    }

    private func calibrateThreeFingerOrigin(touches: [MTTouch], now: CFTimeInterval) {
        let avg = averagePosition(touches)
        threeFingerStartTime = now
        threeFingerOriginX = avg.x
        threeFingerOriginY = avg.y
        threeFingerMaxDrift = 0
        hasCalibratedThreeFingers = true
    }

    private func endSession(now: CFTimeInterval) {
        if switcherActive {
            SwitcherController.shared.commit()
            switcherActive = false
            hasActivatedSwipe = false
            hasCalibratedThreeFingers = false
            sessionPeakFingers = 0
            return
        }

        let peak = sessionPeakFingers
        let wasSwipe = hasActivatedSwipe
        let calibrated = hasCalibratedThreeFingers
        let drift = threeFingerMaxDrift
        let duration = now - (calibrated ? threeFingerStartTime : sessionStartTime)

        // Reset session state
        sessionPeakFingers = 0
        hasActivatedSwipe = false
        hasCalibratedThreeFingers = false
        threeFingerMaxDrift = 0

        // Check middle click tap conditions
        guard !wasSwipe, peak == 3, duration <= tapMaxDuration, drift <= tapMaxDrift else { return }

        ActionPoster.postMiddleClick()
    }

    private func trackThreeFinger(touches: [MTTouch], now: CFTimeInterval) {
        if !hasCalibratedThreeFingers {
            calibrateThreeFingerOrigin(touches: touches, now: now)
        }

        let avg = averagePosition(touches)
        let dx = avg.x - threeFingerOriginX
        let dy = avg.y - threeFingerOriginY
        let distance = hypot(dx, dy)
        threeFingerMaxDrift = max(threeFingerMaxDrift, distance)

        if !switcherActive && !hasActivatedSwipe {
            // Activate switcher once movement crosses activation threshold
            if distance >= swipeActivationThreshold {
                hasActivatedSwipe = true
                switcherActive = true

                let initialDirection = dx >= 0 ? 1 : -1
                SwitcherController.shared.showWindowSwitcher(initialDirection: initialDirection)

                gestureOriginX = avg.x
                gestureOriginY = avg.y
                let initialIndex = (initialDirection > 0 && SwitcherController.shared.totalWindowsCount > 1) ? 1 : 0
                let cols = max(1, SwitcherController.shared.gridColumns)
                gestureBaseRow = initialIndex / cols
                gestureBaseCol = initialIndex % cols
            }
            return
        }

        // Direct 1-to-1 Spatial 2D Physical Tracking:
        let relX = avg.x - gestureOriginX
        let relY = avg.y - gestureOriginY

        let colOffset = Int(round(relX / switchStepDistanceX))
        // Trackpad Multitouch: moving fingers UP increases avg.y (towards screen), relY > 0 -> rowOffset is negative (towards top row 0)
        // Moving fingers DOWN decreases avg.y (towards wrist), relY < 0 -> rowOffset is positive (towards bottom row)
        let rowOffset = -Int(round(relY / switchStepDistanceY))

        let targetRow = gestureBaseRow + rowOffset
        let targetCol = gestureBaseCol + colOffset

        SwitcherController.shared.selectGrid(row: targetRow, col: targetCol)
    }

    var isGestureInProgress: Bool {
        lastCount > 0 || sessionPeakFingers > 0 || switcherActive || SwitcherController.shared.isVisible
    }

    private func averagePosition(_ touches: [MTTouch]) -> (x: Float, y: Float) {
        guard !touches.isEmpty else { return (threeFingerOriginX, threeFingerOriginY) }
        var sx: Float = 0
        var sy: Float = 0
        for t in touches {
            sx += t.normalized.position.x
            sy += t.normalized.position.y
        }
        let n = Float(touches.count)
        return (sx / n, sy / n)
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

