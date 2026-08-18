import AppKit
import ApplicationServices

final class SwitcherController {
    static let shared = SwitcherController()

    private let panel = SwitcherPanel()

    var isVisible: Bool {
        panel.isActive
    }

    func start() {
        panel.onCommit = { [weak self] item in
            self?.activateWindow(item)
        }
    }

    func showWindowSwitcher(initialIndex: Int = 0) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showWindowSwitcher(initialIndex: initialIndex)
            }
            return
        }

        let windows = WindowEngine.shared.windows()
        guard !windows.isEmpty else { return }

        panel.onCommit = { [weak self] item in
            self?.activateWindow(item)
        }
        panel.show(windows: windows, initialIndex: initialIndex)
    }

    func step(direction: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.step(direction: direction)
            }
            return
        }

        if !panel.isActive {
            let windows = WindowEngine.shared.windows()
            guard !windows.isEmpty else { return }
            let initialIndex: Int
            if direction > 0 {
                initialIndex = windows.count > 1 ? 1 : 0
            } else {
                initialIndex = windows.count - 1
            }
            panel.onCommit = { [weak self] item in
                self?.activateWindow(item)
            }
            panel.show(windows: windows, initialIndex: initialIndex)
            return
        }

        if direction > 0 {
            panel.next()
        } else {
            panel.previous()
        }
    }

    func stepGrid(rowDelta: Int, colDelta: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stepGrid(rowDelta: rowDelta, colDelta: colDelta)
            }
            return
        }

        if !panel.isActive {
            step(direction: colDelta >= 0 ? 1 : -1)
            return
        }

        panel.stepGrid(rowDelta: rowDelta, colDelta: colDelta)
    }

    func closeSelectedWindow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.closeSelectedWindow()
            }
            return
        }

        guard let item = panel.selectedItem else { return }
        closeWindow(item)
        panel.removeSelectedWindow()
    }

    func quitSelectedApp() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.quitSelectedApp()
            }
            return
        }

        guard let item = panel.selectedItem else { return }
        let app = item.app
        app.terminate()
        panel.removeAllWindows(forApp: app)
    }

    func cancel() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cancel()
            }
            return
        }
        panel.dismiss()
    }

    func commit() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.commit()
            }
            return
        }
        guard panel.isActive else { return }
        panel.commit()
    }

    private func closeWindow(_ item: WindowItem) {
        var rawButton: AnyObject?
        // 1. Try standard close button
        if AXUIElementCopyAttributeValue(item.axWindow, kAXCloseButtonAttribute as CFString, &rawButton) == .success,
           let closeBtn = rawButton {
            let btnElement = closeBtn as! AXUIElement
            AXUIElementPerformAction(btnElement, kAXPressAction as CFString)
            return
        }

        // 2. Try perform close / cancel action directly on window
        if AXUIElementPerformAction(item.axWindow, "AXClose" as CFString) == .success {
            return
        }
        AXUIElementPerformAction(item.axWindow, "AXCancel" as CFString)
    }

    private func activateWindow(_ item: WindowItem) {
        let targetApp = item.app
        let targetWindow = item.axWindow

        // 1. Unminimize if minimized
        var rawMinimized: AnyObject?
        if AXUIElementCopyAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, &rawMinimized) == .success,
           let isMinimized = rawMinimized as? Bool, isMinimized {
            AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // 2. Set window focus and main attributes
        AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        // 3. Raise the window
        AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)

        // 4. Set application to frontmost and activate
        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if #available(macOS 14.0, *) {
            targetApp.activate()
        } else {
            targetApp.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
