import Foundation
import AppKit

// Reads raw per-finger touch frames from the trackpad and turns them into
// gestures. Each touch session is tracked from the moment fingers land to the
// moment they all lift, deciding "tap" vs "horizontal swipe" vs "vertical gesture"
// based on movement axis, finger count, and duration.
final class GestureEngine {
    static let shared = GestureEngine()

    private var device: MTDeviceRef?
    private let debug = ProcessInfo.processInfo.environment["TPG_DEBUG"] != nil

    // session state
    private var lastCount: Int32 = 0
    private var sessionPeakFingers: Int32 = 0
    private var sessionStartTime: CFTimeInterval = 0
    private var sessionStartX: Float = 0
    private var sessionStartY: Float = 0
    private var lastStepX: Float = 0
    private var lastStepY: Float = 0
    private var switcherActive = false
    private var crossedSwipeThreshold = false
    private var isVerticalGesture = false

    // --- Tunables ---------------------------------------------------------
    /// How far (in normalized 0...1 trackpad width/height) fingers can drift
    /// during a tap before it's reclassified as a swipe.
    private let tapMovementThreshold: Float = 0.04
    /// Max time fingers can be down and still count as a tap, not a stalled swipe.
    private let tapMaxDuration: CFTimeInterval = 0.35
    /// Horizontal distance per window-switcher step (three-finger swipe).
    private let switchStepDistance: Float = 0.08
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

        // If 4 or more fingers are detected, immediately cancel and lock out 3-finger switcher
        if count >= 4 || sessionPeakFingers >= 4 {
            if switcherActive {
                SwitcherController.shared.cancel()
                switcherActive = false
            }
        }

        if count != lastCount {
            if lastCount == 0 && count > 0 {
                beginSession(touches: touches, now: now, count: count)
            } else if count == 0 && lastCount > 0 {
                endSession(now: now)
            }
            lastCount = count
        }

        // Strictly ensure exactly 3 fingers throughout the entire session
        if count == 3 && sessionPeakFingers == 3 {
            trackThreeFinger(touches: touches)
        }
    }

    private func beginSession(touches: [MTTouch], now: CFTimeInterval, count: Int32) {
        sessionStartTime = now
        sessionPeakFingers = count
        let avg = averagePosition(touches)
        sessionStartX = avg.x
        sessionStartY = avg.y
        lastStepX = avg.x
        lastStepY = avg.y
        switcherActive = false
        crossedSwipeThreshold = false
        isVerticalGesture = false
    }

    private func endSession(now: CFTimeInterval) {
        if switcherActive {
            SwitcherController.shared.commit()
            switcherActive = false
            sessionPeakFingers = 0
            isVerticalGesture = false
            return
        }

        let elapsed = now - sessionStartTime
        let peak = sessionPeakFingers
        let wasVertical = isVerticalGesture
        sessionPeakFingers = 0
        isVerticalGesture = false

        guard !crossedSwipeThreshold, !wasVertical, elapsed < tapMaxDuration else { return }

        if peak == 3 {
            ActionPoster.postMiddleClick()
        }
    }

    private func trackThreeFinger(touches: [MTTouch]) {
        guard sessionPeakFingers == 3 else { return }

        let avg = averagePosition(touches)
        let dx = avg.x - sessionStartX
        let dy = avg.y - sessionStartY

        if !switcherActive {
            // If movement is predominantly vertical, isolate as vertical gesture
            if abs(dy) > tapMovementThreshold && abs(dy) > abs(dx) * 1.25 {
                isVerticalGesture = true
                return
            }

            // Only trigger horizontal switcher if horizontal movement dominates vertical movement
            if !isVerticalGesture && abs(dx) > tapMovementThreshold && abs(dx) > abs(dy) * 1.25 {
                crossedSwipeThreshold = true
                switcherActive = true
                SwitcherController.shared.step(direction: dx > 0 ? 1 : -1)
                lastStepX = avg.x
                lastStepY = avg.y
            }
            return
        }

        // Switcher is already active: step forward/backward on horizontal delta
        let stepDelta = avg.x - lastStepX
        if abs(stepDelta) >= switchStepDistance {
            SwitcherController.shared.step(direction: stepDelta > 0 ? 1 : -1)
            lastStepX = avg.x
            lastStepY = avg.y
        }
    }

    private func averagePosition(_ touches: [MTTouch]) -> (x: Float, y: Float) {
        guard !touches.isEmpty else { return (sessionStartX, sessionStartY) }
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
        DispatchQueue.main.async {
            GestureEngine.shared.handleFrame([], count: 0)
        }
        return 0
    }
    let buffer = UnsafeBufferPointer(start: data, count: Int(numFingers))
    let touches = Array(buffer)
    DispatchQueue.main.async {
        GestureEngine.shared.handleFrame(touches, count: numFingers)
    }
    return 0
}
