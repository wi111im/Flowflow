import AppKit
import ApplicationServices

/// Reads only the player's standard play/pause menu command, never activates it.
enum PlayerFallbackState {
    static func playing(pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let value = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let menuBar = value as! AXUIElement
        var matches = [Bool]()
        collect(menuBar, depth: 0, into: &matches)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private static func collect(_ element: AXUIElement, depth: Int, into matches: inout [Bool]) {
        guard depth < 5 else { return }
        AXUIElementSetMessagingTimeout(element, 0.3)
        if let role = attribute(element, kAXRoleAttribute) as? String, role == kAXMenuItemRole,
           let title = attribute(element, kAXTitleAttribute) as? String,
           (attribute(element, kAXEnabledAttribute) as? Bool) != false {
            switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "暂停", "暫停", "pause": matches.append(true)
            case "播放", "play": matches.append(false)
            default: break
            }
        }
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children.prefix(100) { collect(child, depth: depth + 1, into: &matches) }
    }
}
