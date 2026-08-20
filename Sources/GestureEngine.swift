import Foundation
import AppKit

// Reads raw per-finger touch frames from the trackpad and turns them into
// gestures. Direct 1-to-1 physical spatial 2D mapping for window switching
// and ultra-responsive 3-finger middle click taps.
final class GestureEngine {
    static let shared = GestureEngine()

    private var devices: [MTDeviceRef] = []
    private let debug = ProcessInfo.processInfo.environment["TPG_DEBUG"] != nil
    private var wakeObservers: [NSObjectProtocol] = []

    // Thread-safe synchronization and touch state for scroll suppression
    private let lock = NSLock()
    private var rawFingerCount: Int32 = 0
    private var lastThreeFingerTimestamp: CFTimeInterval = 0
    private var gestureEndTimestamp: CFTimeInterval = 0
    private var isThreeFingerActive: Bool = false
    private var isTrackingTouchSession: Bool = false

    // Touch tracking state (accessed on Main thread)
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
    /// Horizontal distance fingers must move from touchdown to activate the switcher.
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

    init() {
        setupWakeObservers()
    }

    private func setupWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let o1 = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
        let o2 = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
        wakeObservers = [o1, o2]
    }

    func start() {
        stop()

        var registeredDevices: [MTDeviceRef] = []

        if let rawList = MTDeviceCreateList() {
            let unmanagedList = rawList.takeRetainedValue()
            let count = CFArrayGetCount(unmanagedList)
            for i in 0..<count {
                if let ptr = CFArrayGetValueAtIndex(unmanagedList, i) {
                    let dev = UnsafeMutableRawPointer(mutating: ptr)
                    MTRegisterContactFrameCallback(dev, multitouchTrampoline)
                    MTDeviceStart(dev, 0)
                    registeredDevices.append(dev)
                }
            }
        }

        if registeredDevices.isEmpty {
            if let def = MTDeviceCreateDefault() {
                MTRegisterContactFrameCallback(def, multitouchTrampoline)
                MTDeviceStart(def, 0)
                registeredDevices.append(def)
            } else {
                NSLog("TrackpadGestures: could not create multitouch device — is a trackpad present?")
            }
        }

        devices = registeredDevices
    }

    func stop() {
        for dev in devices {
            MTUnregisterContactFrameCallback(dev, multitouchTrampoline)
            MTDeviceStop(dev)
        }
        devices.removeAll()
        resetSessionState()
    }

    func restart() {
        stop()
        start()
    }

    /// Pure primitive state check; safe to call from background multitouch thread without instantiating UI.
    var isGestureInProgress: Bool {
        lock.lock()
        let inProgress = isThreeFingerActive || rawFingerCount > 0
        lock.unlock()
        return inProgress || switcherActive
    }

    /// Resets all internal gesture tracking states. Called when gestures end or UI dismisses.
    func resetSessionState() {
        lock.lock()
        rawFingerCount = 0
        isThreeFingerActive = false
        gestureEndTimestamp = CACurrentMediaTime()
        isTrackingTouchSession = false
        lock.unlock()

        lastCount = 0
        sessionPeakFingers = 0
        sessionStartTime = 0
        threeFingerStartTime = 0
        threeFingerOriginX = 0
        threeFingerOriginY = 0
        threeFingerMaxDrift = 0
        hasCalibratedThreeFingers = false
        switcherActive = false
    }

    func markGestureEnded() {
        lock.lock()
        gestureEndTimestamp = CACurrentMediaTime()
        isThreeFingerActive = false
        lock.unlock()
        switcherActive = false
    }

    /// Returns true if scroll wheel events should be dropped to prevent scrolling open background apps.
    var shouldSuppressScroll: Bool {
        let now = CACurrentMediaTime()
        lock.lock()
        let touchingThree = isThreeFingerActive || rawFingerCount >= 3
        let recentThreeFinger = (now - lastThreeFingerTimestamp) < 0.35
        let recentGestureEnd = (now - gestureEndTimestamp) < 0.35
        lock.unlock()

        if touchingThree || recentThreeFinger || recentGestureEnd {
            return true
        }
        if switcherActive || SwitcherPanel.shared.isVisible {
            return true
        }
        return false
    }

    /// Entry point from C callback running on private Multitouch thread.
    fileprivate func handleMultitouchFrame(data: UnsafeMutablePointer<MTTouch>?, count: Int32) {
        let now = CACurrentMediaTime()

        lock.lock()
        rawFingerCount = count
        if count >= 3 {
            lastThreeFingerTimestamp = now
            isThreeFingerActive = true
        } else if count == 0 {
            if isThreeFingerActive {
                gestureEndTimestamp = now
                isThreeFingerActive = false
            }
        }

        let wasTracking = isTrackingTouchSession
        if count >= 3 {
            isTrackingTouchSession = true
        } else if count == 0 {
            isTrackingTouchSession = false
        }
        let shouldDispatchFrame = (count >= 3) || (count == 0 && (wasTracking || switcherActive)) || (count > 0 && (wasTracking || switcherActive))
        lock.unlock()

        guard shouldDispatchFrame else { return }

        if let data = data, count > 0 {
            let buffer = UnsafeBufferPointer(start: data, count: Int(count))
            let touches = Array(buffer)
            DispatchQueue.main.async { [weak self] in
                self?.handleFrame(touches, count: count)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleFrame([], count: 0)
            }
        }
    }

    fileprivate func handleFrame(_ touches: [MTTouch], count: Int32) {
        let now = CACurrentMediaTime()

        if debug {
            NSLog("TPG frame: count=\(count) states=\(touches.map { $0.state })")
        }

        if count == 0 {
            endSession(now: now)
            return
        }

        sessionPeakFingers = max(sessionPeakFingers, count)

        // Lock out 3-finger gestures if 4 or more fingers touch the pad
        if count >= 4 || sessionPeakFingers >= 4 {
            if switcherActive {
                SwitcherPanel.shared.dismiss()
                switcherActive = false
            }
            return
        }

        // Session start boundary
        if lastCount == 0 && count > 0 {
            sessionStartTime = now
            sessionPeakFingers = count
            hasCalibratedThreeFingers = false
            threeFingerMaxDrift = 0
            switcherActive = SwitcherPanel.shared.isVisible
            if switcherActive { gestureBaseRow = 0; gestureBaseCol = 0 }
            if count == 3 { calibrateThreeFingerOrigin(touches: touches, now: now) }
        }
        lastCount = count

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
            resetSessionState()
            return
        }

        markGestureEnded()

        let duration = now - (hasCalibratedThreeFingers ? threeFingerStartTime : sessionStartTime)
        let isTap = sessionPeakFingers == 3 && duration <= tapMaxDuration && threeFingerMaxDrift <= tapMaxDrift

        resetSessionState()

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
            // Activate switcher only on horizontal swipe (left or right) crossing activation threshold
            if abs(dx) >= swipeActivationThreshold && abs(dx) > abs(dy) {
                let initialDirection = dx > 0 ? 1 : -1
                if SwitcherPanel.shared.show(initialDirection: initialDirection) {
                    switcherActive = true
                    gestureOriginX = avgX
                    gestureOriginY = avgY
                    let initialIndex = SwitcherPanel.shared.selectedIndex
                    let cols = max(1, SwitcherPanel.shared.gridColumns)
                    gestureBaseRow = initialIndex / cols
                    gestureBaseCol = initialIndex % cols
                }
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
    GestureEngine.shared.handleMultitouchFrame(data: data, count: numFingers)
    return 0
}
