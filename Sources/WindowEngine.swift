import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

private func axAttr<T>(_ el: AXUIElement, _ key: CFString) -> T? {
    var val: AnyObject?
    return AXUIElementCopyAttributeValue(el, key, &val) == .success ? (val as? T) : nil
}

struct WindowItem: Equatable {
    let appName: String
    let subtitle: String?
    let appIcon: NSImage?
    let title: String
    let axWindow: AXUIElement
    let cgWindowID: CGWindowID
    let app: NSRunningApplication

    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        lhs.cgWindowID != kCGNullWindowID && rhs.cgWindowID != kCGNullWindowID ? lhs.cgWindowID == rhs.cgWindowID : CFEqual(lhs.axWindow, rhs.axWindow)
    }
}

final class WindowEngine {
    static let shared = WindowEngine()
    private var mruHistory: [WindowItem] = []

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recordActiveWindow()
        }
    }

    func recordActiveWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let win: AXUIElement? = axAttr(appEl, kAXFocusedWindowAttribute as CFString) ?? axAttr(appEl, kAXMainWindowAttribute as CFString)
        if let idx = mruHistory.firstIndex(where: { win != nil ? CFEqual($0.axWindow, win!) : $0.app.processIdentifier == app.processIdentifier }) {
            mruHistory.insert(mruHistory.remove(at: idx), at: 0)
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
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 }
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let layer0 = cgList.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

        var discovered: [WindowItem] = []
        var byWid: [CGWindowID: WindowItem] = [:]

        for app in apps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            let axList: [AXUIElement] = axAttr(appEl, kAXWindowsAttribute as CFString) ?? []
            for axWin in axList {
                guard let item = makeWindowItem(for: axWin, app: app, layer0: layer0) else { continue }
                discovered.append(item)
                if item.cgWindowID != kCGNullWindowID { byWid[item.cgWindowID] = item }
            }
        }
        guard !discovered.isEmpty else { mruHistory.removeAll(); return [] }

        // Clean and update existing MRU history with fresh metadata
        var updated = mruHistory.compactMap { mru in discovered.first(where: { $0 == mru }) }

        // Identify current frontmost window and put at position 0 in MRU list
        if let frontApp = NSWorkspace.shared.frontmostApplication, frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)
            let win: AXUIElement? = axAttr(appEl, kAXFocusedWindowAttribute as CFString) ?? axAttr(appEl, kAXMainWindowAttribute as CFString)
            let frontItem = discovered.first(where: { win != nil ? CFEqual($0.axWindow, win!) : $0.app.processIdentifier == frontApp.processIdentifier })
            if let front = frontItem {
                updated.removeAll { $0 == front }
                updated.insert(front, at: 0)
            }
        }

        // Append any windows in layer 0 z-order that aren't yet in MRU history
        for info in layer0 {
            if let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
               let item = byWid[wid], !updated.contains(where: { $0 == item }) {
                updated.append(item)
            }
        }

        // Append any remaining discovered windows (minimized or other spaces)
        for item in discovered where !updated.contains(where: { $0 == item }) { updated.append(item) }

        mruHistory = updated
        return updated
    }

    private func makeWindowItem(for axWindow: AXUIElement, app: NSRunningApplication, layer0: [[String: Any]]) -> WindowItem? {
        let role: String = axAttr(axWindow, kAXRoleAttribute as CFString) ?? ""
        if !role.isEmpty && role != (kAXWindowRole as String) { return nil }

        let subrole: String = axAttr(axWindow, kAXSubroleAttribute as CFString) ?? ""
        if subrole == "AXDesktopWindow" { return nil }

        let size: CGSize? = axAttr(axWindow, kAXSizeAttribute as CFString)
        if let s = size, (s.width < 50 || s.height < 50) { return nil }

        let appName = app.localizedName ?? app.bundleURL?.lastPathComponent ?? "Application"
        var title: String = (axAttr(axWindow, kAXTitleAttribute as CFString) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            if subrole == "AXUnknown" { return nil }
            let doc: String = axAttr(axWindow, kAXDocumentAttribute as CFString) ?? ""
            let desc: String = axAttr(axWindow, kAXDescriptionAttribute as CFString) ?? ""
            title = !doc.isEmpty ? URL(fileURLWithPath: doc).lastPathComponent : (!desc.isEmpty ? desc : appName)
        }

        // Strict Finder rule: Finder must be completely excluded unless at least one standard file/directory window is open
        if app.bundleIdentifier == "com.apple.finder" && (title == "Desktop" || title == "Desktop 1" || subrole == "AXDesktopWindow") {
            return nil
        }

        let (cleanTitle, subtitle) = parseTitleAndSubtitle(title, appName: appName)

        // Resolve CGWindowID
        var cgWid: CGWindowID = kCGNullWindowID
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &wid) == .success && wid > 0 {
            cgWid = wid
        } else {
            // Fallback: match by PID and bounds
            cgWid = matchingWindowID(for: app, size: size, layer0: layer0)
        }

        return WindowItem(appName: appName, subtitle: subtitle, appIcon: app.icon, title: cleanTitle, axWindow: axWindow, cgWindowID: cgWid, app: app)
    }

    private static let profileRegex = try? NSRegularExpression(pattern: #"^(Personal|Work|School|Default|Profile \d+|Guest)\s*[—–-]\s*"#, options: .caseInsensitive)

    private func parseTitleAndSubtitle(_ raw: String, appName: String) -> (String, String?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var subtitle: String? = nil

        // 1. Check for Safari / Browser Profile prefixes (e.g. "Personal — Page Title" or "Work — Page Title")
        if let regex = WindowEngine.profileRegex,
           let match = regex.firstMatch(in: title, range: NSRange(location: 0, length: title.utf16.count)),
           let range = Range(match.range, in: title) {
            subtitle = String(title[range]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–-")))
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Strip redundant trailing app name suffix (e.g. " — Safari", " - Google Chrome", " — Visual Studio Code")
        let suffixes = [" — \(appName)", " - \(appName)", " — Safari", " - Safari", " — Google Chrome", " - Google Chrome", " — Brave", " - Brave", " — Arc", " - Arc", " — Firefox", " - Firefox", " — Visual Studio Code", " - Visual Studio Code", " — Antigravity IDE", " - Antigravity IDE", " — Cursor", " - Cursor", " — Xcode", " - Xcode"]
        for s in suffixes where title.hasSuffix(s) {
            title = String(title.dropLast(s.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. For IDEs & Editors, if title has "Project — File" or "File — Project", extract project into subtitle if no profile was found
        if subtitle == nil {
            let parts = title.components(separatedBy: " — ")
            if parts.count == 2 {
                let p0 = parts[0].trimmingCharacters(in: .whitespaces), p1 = parts[1].trimmingCharacters(in: .whitespaces)
                if p0.contains(".") && !p1.contains(".") { title = p0; subtitle = p1 }
                else if !p0.contains(".") && p1.contains(".") { title = p1; subtitle = p0 }
            }
        }
        return (title.isEmpty ? appName : title, subtitle)
    }

    private func matchingWindowID(for app: NSRunningApplication, size: CGSize?, layer0: [[String: Any]]) -> CGWindowID {
        let wins = layer0.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }
        if wins.count == 1, let wid = wins[0][kCGWindowNumber as String] as? Int { return CGWindowID(wid) }
        if let s = size, let best = wins.min(by: { a, b in
            let bA = a[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let bB = b[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let dA = abs((bA["Width"] as? Double ?? 0) - Double(s.width)) + abs((bA["Height"] as? Double ?? 0) - Double(s.height))
            let dB = abs((bB["Width"] as? Double ?? 0) - Double(s.width)) + abs((bB["Height"] as? Double ?? 0) - Double(s.height))
            return dA < dB
        }), let wid = best[kCGWindowNumber as String] as? Int {
            return CGWindowID(wid)
        }
        return (wins.first?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? kCGNullWindowID
    }
}
