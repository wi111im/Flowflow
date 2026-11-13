import AppKit
import SwiftUI

/// Transparent SwiftUI text consumes the native background-drag hit region.
/// Handle drags in AppKit, reserving the close button and generous resize edges.
struct DesktopFloatingLyricsInteraction: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingLyricsDragView() }
    func updateNSView(_ view: NSView, context: Context) { view.window?.invalidateCursorRects(for: view) }
}

private final class FloatingLyricsDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window, !UserDefaults.standard.bool(forKey: "floatingLyrics.fixedPosition") else { return }
        DesktopFloatingLyricsFramePersistence.isUserAdjusting = true
        defer {
            DesktopFloatingLyricsFramePersistence.isUserAdjusting = false
            DesktopFloatingLyricsFramePersistence.save(window.frame, window: window)
        }
        window.performDrag(with: event)
    }
}
