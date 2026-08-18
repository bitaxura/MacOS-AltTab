import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowItem: Equatable {
    let appName: String
    let subtitle: String?
    let appIcon: NSImage?
    let title: String
    let axWindow: AXUIElement
    let cgWindowID: CGWindowID
    let app: NSRunningApplication

    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        if lhs.cgWindowID != kCGNullWindowID && rhs.cgWindowID != kCGNullWindowID {
            return lhs.cgWindowID == rhs.cgWindowID
        }
        return CFEqual(lhs.axWindow, rhs.axWindow)
    }
}

final class WindowEngine {
    static let shared = WindowEngine()

    private var mruHistory: [WindowItem] = []

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.recordActiveWindow()
        }
    }

    func recordActiveWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.activationPolicy == .regular,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var rawFocusedWindow: AnyObject?
        var axWindow: AXUIElement? = nil

        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawFocusedWindow) == .success,
           let win = rawFocusedWindow {
            axWindow = (win as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &rawFocusedWindow) == .success,
                  let win = rawFocusedWindow {
            axWindow = (win as! AXUIElement)
        }

        if let targetAX = axWindow {
            if let index = mruHistory.firstIndex(where: { CFEqual($0.axWindow, targetAX) }) {
                let item = mruHistory.remove(at: index)
                mruHistory.insert(item, at: 0)
            }
        } else if let index = mruHistory.firstIndex(where: { $0.app.processIdentifier == frontApp.processIdentifier }) {
            let item = mruHistory.remove(at: index)
            mruHistory.insert(item, at: 0)
        }
    }

    func promoteToMRUFront(_ item: WindowItem) {
        mruHistory.removeAll { $0 == item }
        mruHistory.insert(item, at: 0)
    }

    func removeWindow(_ item: WindowItem) {
        mruHistory.removeAll { $0 == item }
    }

    func windows() -> [WindowItem] {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 0
        }

        let cgInfoList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let layer0CGWindows = cgInfoList.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

        var discoveredItems: [WindowItem] = []
        var itemByWindowID: [CGWindowID: WindowItem] = [:]

        for app in runningApps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let axWindowsList = self.axWindows(for: appElement)

            for axWindow in axWindowsList {
                guard let item = self.makeWindowItem(for: axWindow, app: app, layer0Windows: layer0CGWindows) else {
                    continue
                }
                discoveredItems.append(item)
                if item.cgWindowID != kCGNullWindowID {
                    itemByWindowID[item.cgWindowID] = item
                }
            }
        }

        guard !discoveredItems.isEmpty else {
            mruHistory.removeAll()
            return []
        }

        // Clean and update existing MRU history with fresh metadata
        var updatedMRU: [WindowItem] = []
        for mruItem in mruHistory {
            if let freshItem = discoveredItems.first(where: { $0 == mruItem }) {
                updatedMRU.append(freshItem)
            }
        }

        // Identify current frontmost window
        let frontApp = NSWorkspace.shared.frontmostApplication
        var currentFrontItem: WindowItem? = nil
        if let frontApp = frontApp, frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
            var rawFocused: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawFocused) == .success,
               let win = rawFocused {
                let ax = win as! AXUIElement
                currentFrontItem = discoveredItems.first(where: { CFEqual($0.axWindow, ax) })
            } else if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &rawFocused) == .success,
                      let win = rawFocused {
                let ax = win as! AXUIElement
                currentFrontItem = discoveredItems.first(where: { CFEqual($0.axWindow, ax) })
            }
            if currentFrontItem == nil {
                currentFrontItem = discoveredItems.first(where: { $0.app.processIdentifier == frontApp.processIdentifier })
            }
        }

        // Put the currently active window at position 0 in MRU list
        if let front = currentFrontItem {
            updatedMRU.removeAll { $0 == front }
            updatedMRU.insert(front, at: 0)
        }

        // Append any windows in layer 0 z-order that aren't yet in MRU history
        for info in layer0CGWindows {
            guard let rawWid = info[kCGWindowNumber as String] as? Int else { continue }
            let wid = CGWindowID(rawWid)
            if let item = itemByWindowID[wid], !updatedMRU.contains(where: { $0 == item }) {
                updatedMRU.append(item)
            }
        }

        // Append any remaining discovered windows (minimized or other spaces)
        for item in discoveredItems {
            if !updatedMRU.contains(where: { $0 == item }) {
                updatedMRU.append(item)
            }
        }

        self.mruHistory = updatedMRU
        return updatedMRU
    }

    private func axWindows(for appElement: AXUIElement) -> [AXUIElement] {
        var rawWindows: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard status == .success, let windows = rawWindows as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private func makeWindowItem(for axWindow: AXUIElement, app: NSRunningApplication, layer0Windows: [[String: Any]]) -> WindowItem? {
        // Verify role
        let role = value(for: axWindow, key: kAXRoleAttribute as CFString) as? String ?? ""
        if !role.isEmpty && role != (kAXWindowRole as String) {
            return nil
        }

        // Verify subrole
        let subrole = value(for: axWindow, key: kAXSubroleAttribute as CFString) as? String ?? ""
        if subrole == "AXDesktopWindow" {
            return nil
        }

        // Check size
        let size = value(for: axWindow, key: kAXSizeAttribute as CFString) as? CGSize
        if let size, (size.width < 50 || size.height < 50) {
            return nil
        }

        let appName = app.localizedName ?? app.bundleURL?.lastPathComponent ?? "Application"
        let isFinder = app.bundleIdentifier == "com.apple.finder"

        // Window title resolution
        var rawTitle = (value(for: axWindow, key: kAXTitleAttribute as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawTitle.isEmpty {
            if subrole == "AXUnknown" {
                return nil
            }
            if let doc = (value(for: axWindow, key: kAXDocumentAttribute as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty {
                rawTitle = URL(fileURLWithPath: doc).lastPathComponent
            } else if let desc = (value(for: axWindow, key: kAXDescriptionAttribute as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                rawTitle = desc
            } else {
                rawTitle = appName
            }
        }

        // Strict Finder rule: Finder must be completely excluded unless at least one standard file/directory window is open
        if isFinder {
            if rawTitle == "Desktop" || rawTitle == "Desktop 1" || subrole == "AXDesktopWindow" {
                return nil
            }
        }

        let (cleanTitle, subtitle) = parseTitleAndSubtitle(rawTitle, appName: appName, app: app)

        // Resolve CGWindowID
        var cgWindowID: CGWindowID = kCGNullWindowID
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &wid) == .success && wid > 0 {
            cgWindowID = wid
        } else {
            // Fallback: match by PID and bounds
            cgWindowID = matchingWindowID(for: app, size: size, layer0Windows: layer0Windows)
        }

        return WindowItem(
            appName: appName,
            subtitle: subtitle,
            appIcon: app.icon,
            title: cleanTitle,
            axWindow: axWindow,
            cgWindowID: cgWindowID,
            app: app
        )
    }

    private static let profileRegex = try? NSRegularExpression(
        pattern: #"^(Personal|Work|School|Default|Profile \d+|Guest)\s*[—–-]\s*"#,
        options: .caseInsensitive
    )

    private func parseTitleAndSubtitle(_ rawTitle: String, appName: String, app: NSRunningApplication) -> (title: String, subtitle: String?) {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var subtitle: String? = nil

        // 1. Check for Safari / Browser Profile prefixes (e.g. "Personal — Page Title" or "Work — Page Title")
        if let regex = WindowEngine.profileRegex,
           let match = regex.firstMatch(in: title, options: [], range: NSRange(location: 0, length: title.utf16.count)),
           let range = Range(match.range, in: title) {
            let matchedProfile = String(title[range]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–-")))
            subtitle = matchedProfile
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Strip redundant trailing app name suffix (e.g. " — Safari", " - Google Chrome", " — Visual Studio Code")
        let suffixes = [
            " — \(appName)", " - \(appName)",
            " — Safari", " - Safari", " — Google Chrome", " - Google Chrome",
            " — Brave", " - Brave", " — Arc", " - Arc", " — Firefox", " - Firefox",
            " — Visual Studio Code", " - Visual Studio Code", " — Antigravity IDE", " - Antigravity IDE",
            " — Cursor", " - Cursor", " — Xcode", " - Xcode"
        ]
        for suffix in suffixes {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 3. For IDEs & Editors, if title has "Project — File" or "File — Project", extract project into subtitle if no profile was found
        if subtitle == nil {
            let parts = title.components(separatedBy: " — ")
            if parts.count == 2 {
                let part0 = parts[0].trimmingCharacters(in: .whitespaces)
                let part1 = parts[1].trimmingCharacters(in: .whitespaces)
                if part0.contains(".") && !part1.contains(".") {
                    title = part0
                    subtitle = part1
                } else if !part0.contains(".") && part1.contains(".") {
                    title = part1
                    subtitle = part0
                }
            }
        }

        if title.isEmpty {
            title = appName
        }

        return (title, subtitle)
    }

    private func matchingWindowID(for app: NSRunningApplication, size: CGSize?, layer0Windows: [[String: Any]]) -> CGWindowID {
        let appPID = Int(app.processIdentifier)
        let appWindows = layer0Windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == appPID }
        guard !appWindows.isEmpty else { return kCGNullWindowID }

        if appWindows.count == 1, let wid = appWindows[0][kCGWindowNumber as String] as? Int {
            return CGWindowID(wid)
        }

        if let targetSize = size {
            var bestWid: CGWindowID = kCGNullWindowID
            var bestDiff: CGFloat = CGFloat.greatestFiniteMagnitude
            for info in appWindows {
                guard let windowNumber = info[kCGWindowNumber as String] as? Int,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any]
                else { continue }

                let w = CGFloat(bounds["Width"] as? Double ?? 0)
                let h = CGFloat(bounds["Height"] as? Double ?? 0)
                let diff = abs(w - targetSize.width) + abs(h - targetSize.height)
                if diff < bestDiff {
                    bestDiff = diff
                    bestWid = CGWindowID(windowNumber)
                }
            }
            if bestWid != kCGNullWindowID {
                return bestWid
            }
        }

        if let firstInfo = appWindows.first, let firstWid = firstInfo[kCGWindowNumber as String] as? Int {
            return CGWindowID(firstWid)
        }

        return kCGNullWindowID
    }

    private func value(for axElement: AXUIElement, key: CFString) -> Any? {
        var rawValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(axElement, key, &rawValue)
        guard status == .success else { return nil }
        return rawValue
    }
}
