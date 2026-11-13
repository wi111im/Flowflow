import AppKit
import SwiftUI

/// The native font menu also acts as an immediate keyboard stepper on hover.
struct LyricsFontPicker: NSViewRepresentable {
    @Binding var selection: String
    let families: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HoverFontPopUpButton {
        let button = HoverFontPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        button.setAccessibilityLabel("字体")
        button.toolTip = "鼠标停在这里，按 ↑ 或 ↓ 即时切换字体"
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        return button
    }

    func updateNSView(_ button: HoverFontPopUpButton, context: Context) {
        context.coordinator.parent = self
        guard !button.isMenuTracking else { return }
        let values = [""] + families
        if button.families != values {
            button.families = values
            button.removeAllItems()
            for family in values {
                button.addItem(withTitle: family.isEmpty ? "系统默认" : LyricsFontFamily.displayName(family))
                button.lastItem?.representedObject = family
            }
        }
        let selectedIndex = values.firstIndex(of: selection) ?? 0
        if button.indexOfSelectedItem != selectedIndex { button.selectItem(at: selectedIndex) }
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        weak var button: HoverFontPopUpButton?
        var parent: LyricsFontPicker
        private var originalSelection = ""
        private var committed = false
        init(_ parent: LyricsFontPicker) { self.parent = parent }

        @objc func choose(_ sender: NSPopUpButton) {
            committed = true
            if let family = sender.selectedItem?.representedObject as? String { parent.selection = family }
        }

        func menuWillOpen(_ menu: NSMenu) {
            originalSelection = parent.selection
            committed = false
            button?.isMenuTracking = true
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            if let family = item?.representedObject as? String { parent.selection = family }
        }

        func menuDidClose(_ menu: NSMenu) {
            button?.isMenuTracking = false
            let original = originalSelection
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.committed else { return }
                self.parent.selection = original
            }
        }
    }
}

final class HoverFontPopUpButton: NSPopUpButton {
    var families = [String]()
    // Native menu tracking handles arrows itself; its delegate publishes previews.
    var isMenuTracking = false
    private var hoverTrackingArea: NSTrackingArea?
    private weak var previousFirstResponder: NSResponder?
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let window, window.isKeyWindow, window.firstResponder !== self else { return }
        previousFirstResponder = window.firstResponder
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if window?.firstResponder === self { window?.makeFirstResponder(previousFirstResponder) }
        previousFirstResponder = nil
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              event.keyCode == 125 || event.keyCode == 126 else { super.keyDown(with: event); return }
        let direction = event.keyCode == 125 ? 1 : -1
        let next = min(numberOfItems - 1, max(0, indexOfSelectedItem + direction))
        guard next >= 0, next != indexOfSelectedItem else { return }
        selectItem(at: next)
        sendAction(action, to: target)
    }
}
