import AppKit
import ApplicationServices

enum NetEaseFavorite {
    static let bundleID = "com.netease.163music"

    static func state(for title: String) -> Bool? {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "喜欢歌曲", "Like": return false
        case "取消喜欢", "Dislike": return true
        default: return nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map {
            AXUIElementSetMessagingTimeout($0, 1)
            return $0
        }
    }

    private static func item() -> (AXUIElement, Bool)? {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        guard let bar = attribute(element, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let menuBar = bar as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBar, 1)
        for top in children(menuBar) {
            for menu in children(top) {
                for candidate in children(menu) {
                    guard let title = attribute(candidate, kAXTitleAttribute) as? String,
                          let value = state(for: title),
                          (attribute(candidate, "AXMenuItemCmdChar") as? String)?.uppercased() == "L" else { continue }
                    return (candidate, value)
                }
            }
        }
        return nil
    }

    static func read() -> Bool? { item()?.1 }

    static func toggle(expected: Bool) -> Bool? {
        guard let (element, current) = item(), current == expected,
              (attribute(element, kAXEnabledAttribute) as? Bool) != false,
              AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return nil }
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.1)
            if let value = read(), value != current { return value }
        }
        return nil
    }
}
