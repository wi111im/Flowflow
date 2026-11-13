import AppKit
import SwiftUI

struct DesktopFloatingLyricsWindowConfiguration: NSViewRepresentable {
    @Binding var hovering: Bool
    var controlsEnabled = true
    func makeNSView(context: Context) -> NSView { DesktopFloatingLyricsWindowConfigurationView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? DesktopFloatingLyricsWindowConfigurationView else { return }
        view.controlsEnabled = controlsEnabled
        view.onHoverChange = { value in if hovering != value { DispatchQueue.main.async { hovering = value } } }
        view.checkPointer()
    }
}

enum DesktopFloatingLyricsWindowMetrics {
    static let defaultWidth: CGFloat = 420
    static let defaultHeight: CGFloat = 132
    static let minimumWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 112
}

private final class DesktopFloatingLyricsWindowConfigurationView: NSView {
    var controlsEnabled = true
    var onHoverChange: ((Bool) -> Void)?
    private var hovering = false
    private var pointerTimer: Timer?
    deinit { pointerTimer?.invalidate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pointerTimer?.invalidate(); pointerTimer = nil }
        else if pointerTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPointer() }
            }
            timer.tolerance = 0.01
            pointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        checkPointer()
    }
    func checkPointer() {
        guard let window else { return }
        // Do not interrupt a drag when the pointer moves off the text.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let pointer = NSEvent.mouseLocation
        // Both hit regions are inside the window. Most pointer checks can skip
        // walking the SwiftUI/AppKit view tree entirely.
        let mayHit = window.isVisible && window.frame.insetBy(dx: -2, dy: -2).contains(pointer)
        let overInk = mayHit && DesktopFloatingLyricsInkHitView.containsInk(
            in: window.contentView, screenPoint: pointer, window: window)
        let overControl = mayHit && DesktopHoverControlView.containsControl(
            in: window.contentView, screenPoint: pointer, window: window)
        let nextHover = controlsEnabled && overControl
        if nextHover != hovering { hovering = nextHover; onHoverChange?(nextHover) }
        let ignoresMouseEvents = !(overInk || overControl)
        if window.ignoresMouseEvents != ignoresMouseEvents { window.ignoresMouseEvents = ignoresMouseEvents }
        if window.acceptsMouseMovedEvents == ignoresMouseEvents { window.acceptsMouseMovedEvents = !ignoresMouseEvents }
    }
}

@MainActor enum DesktopFloatingLyricsFramePersistence {
    static var isUserAdjusting = false
    static let key = "floatingLyrics.savedWindowFrame"
    static func save(_ frame: NSRect, window: NSWindow, clearPreset: Bool = true) {
        // Only called by explicit user drag, resize or the reset-position button.
        if clearPreset { UserDefaults.standard.removeObject(forKey: LyricsPositionPreset.selectionKey) }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
        FloatingLyricsWindowController.shared.updateTravelDistance(for: window)
    }
    static func savedFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let text = defaults.string(forKey: key) else { return nil }
        let frame = NSRectFromString(text)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 300, frame.height >= 112 else { return nil }
        return frame
    }
}

/// Marks the compact text layout before full-width framing and shadows.
/// Hit testing uses its live bounds; no bitmap mask is needed or generated.
struct DesktopFloatingLyricsInkHitRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DesktopFloatingLyricsInkHitView {
        DesktopFloatingLyricsInkHitView()
    }
    func updateNSView(_ view: DesktopFloatingLyricsInkHitView, context: Context) { }
}

// Contributes to preset positioning without expanding the interactive ink area.
struct DesktopFloatingLyricsLayoutAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> DesktopFloatingLyricsInkHitView {
        let view = DesktopFloatingLyricsInkHitView()
        view.layoutOnly = true
        return view
    }
    func updateNSView(_ view: DesktopFloatingLyricsInkHitView, context: Context) { }
}

final class DesktopFloatingLyricsInkHitView: NSView {
    var layoutOnly = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func containsInk(at screenPoint: NSPoint, window: NSWindow) -> Bool {
        guard !layoutOnly, !isHidden, self.window === window,
              bounds.width > 0, bounds.height > 0 else { return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        // This view is the text's compact layout BEFORE the full-width frame.
        // Include character/word spacing and a two-point margin, not window padding.
        return bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    static func inkBounds(in view: NSView?, window: NSWindow) -> NSRect? {
        guard let view, !view.isHidden else { return nil }
        var result: NSRect?
        if let marker = view as? DesktopFloatingLyricsInkHitView,
           marker.window === window, marker.bounds.width > 0, marker.bounds.height > 0 {
            result = marker.convert(marker.bounds, to: nil)
        }
        for child in view.subviews {
            if let bounds = inkBounds(in: child, window: window) {
                result = result.map { $0.union(bounds) } ?? bounds
            }
        }
        return result
    }

    static func containsInk(in view: NSView?, screenPoint: NSPoint, window: NSWindow) -> Bool {
        guard let view, !view.isHidden else { return false }
        if let ink = view as? DesktopFloatingLyricsInkHitView,
           ink.containsInk(at: screenPoint, window: window) { return true }
        return view.subviews.contains {
            containsInk(in: $0, screenPoint: screenPoint, window: window)
        }
    }
}

// Markers define the two ends of the control row, including the gaps.
struct DesktopHoverControlRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DesktopHoverControlView { DesktopHoverControlView() }
    func updateNSView(_ view: DesktopHoverControlView, context: Context) { }
}
final class DesktopHoverControlView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private static func controlBounds(in view: NSView?, window: NSWindow) -> NSRect? {
        guard let view, !view.isHidden else { return nil }
        var result: NSRect?
        if let marker = view as? DesktopHoverControlView, marker.window === window,
           marker.bounds.width > 0, marker.bounds.height > 0 {
            result = marker.convert(marker.bounds, to: nil)
        }
        for subview in view.subviews {
            if let child = controlBounds(in: subview, window: window) {
                result = result.map { $0.union(child) } ?? child
            }
        }
        return result
    }
    static func containsControl(in view: NSView?, screenPoint: NSPoint, window: NSWindow) -> Bool {
        guard let bounds = controlBounds(in: view, window: window) else { return false }
        return bounds.contains(window.convertPoint(fromScreen: screenPoint))
    }
}
