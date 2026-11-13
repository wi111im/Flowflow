import AppKit
import SwiftUI
import Observation
import QuartzCore

/// Unlike a SwiftUI-managed titled window, this panel accepts the exact frame,
/// including negative coordinates and a top edge beyond the current screen.
final class UnconstrainedLyricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor @Observable final class ScreenCharacterMotion {
    var progress: Double
    var offset: CGSize
    var active = false
    var entering = true
    var rightFirst = false
    var centerFirst = false
    init(progress: Double, offset: CGSize) { self.progress = progress; self.offset = offset }
}

enum CharacterScreenTransition {
    static let pauseDelay: TimeInterval = 5
    static let duration: TimeInterval = 1.0
    static func travelProgress(_ progress: Double, index: Int, total: Int, rightFirst: Bool = false, centerFirst: Bool = false, entering: Bool = true) -> Double {
        let order = rightFirst ? max(0, total - 1 - index) : index
        let fraction: Double
        if centerFirst && total > 1 {
            fraction = min(1, abs(Double(index) - Double(total - 1) / 2) / (Double(total - 1) / 2))
        } else {
            fraction = total > 1 ? min(1, max(0, Double(order) / Double(total - 1))) : 0
        }
        let delay = (entering ? fraction : (total > 1 ? 1 - fraction : 0)) * 0.5
        let elapsed = entering ? progress : 1 - progress
        let motion = min(1, max(0, elapsed * 1.5 - delay))
        let eased = entering ? 1 - pow(1 - motion, 3) : pow(motion, 3)
        return entering ? eased : 1 - eased
    }
    static func presetOrder(offsetX: CGFloat) -> (rightFirst: Bool, centerFirst: Bool) {
        if abs(offsetX) < 0.5 { return (false, true) }
        return (offsetX < 0, false)
    }
    static func displacement(for frame: NSRect, screens: [NSRect], upward: Bool = false) -> CGFloat {
        guard let first = screens.first else { return 0 }
        let bounds = screens.dropFirst().reduce(first) { $0.union($1) }
        // SwiftUI uses a downward-positive Y axis. Translate the entire
        // lyric beyond the bottom of every connected display.
        return upward ? -(bounds.maxY - frame.minY + 24) : frame.maxY - bounds.minY + 24
    }
}

@MainActor @Observable final class FloatingLyricsWindowController {
    static let shared = FloatingLyricsWindowController()
    var model: DesktopAppModel?
    private(set) var panel: UnconstrainedLyricsPanel?
    private(set) var isVisible = false
    private var autoHidden = false
    private var pendingPause: DispatchWorkItem?
    private var lastPlaying: Bool?
    private var needsInitialLyricsAnimation = false
    private var transitionFrame: NSRect?
    private var normalContainer: NSView?
    private var hostingView: NSView?
    private let screenMotion = ScreenCharacterMotion(progress: 1, offset: .zero)
    private var generation = 0
    private var pendingWidth: (CGFloat, FloatingLyricsTextAlignment)?
    private var pendingPreset: LyricsPositionPreset?
    private var pendingPresetReposition: DispatchWorkItem?
    private var cachedPresetFrames: [LyricsPositionPreset: NSRect] = [:]
    private var cachedPresetInk: [LyricsPositionPreset: NSRect] = [:]

    private let bottomInsetKey = "floatingLyrics.referenceBottomInset"
    private let topCenterInsetKey = "floatingLyrics.referenceTopCenterInsetV2"
    private let presetOffsetXKey = "floatingLyrics.presetOffsetX"
    private let presetOffsetYKey = "floatingLyrics.presetOffsetY"

    func captureReferencePositionIfNeeded() {
        guard let panel, transitionFrame == nil, let screen = panel.screen ?? NSScreen.main,
              let localInk = DesktopFloatingLyricsInkHitView.inkBounds(in: panel.contentView, window: panel) else { return }
        let ink = panel.convertToScreen(localInk)
        if UserDefaults.standard.object(forKey: bottomInsetKey) == nil {
            UserDefaults.standard.set(ink.minY - screen.frame.minY, forKey: bottomInsetKey)
        }
        if UserDefaults.standard.object(forKey: topCenterInsetKey) == nil {
            UserDefaults.standard.set(screen.frame.maxY - ink.maxY, forKey: topCenterInsetKey)
        }
    }

    func applyPositionPreset(_ preset: LyricsPositionPreset) {
        if transitionFrame != nil { pendingPreset = preset; return }
        UserDefaults.standard.removeObject(forKey: presetOffsetXKey)
        UserDefaults.standard.removeObject(forKey: presetOffsetYKey)
        refreshPresetFrames()
        guard let panel,
              let target = cachedPresetFrames[preset], let projectedInk = cachedPresetInk[preset],
              let originalInk = DesktopFloatingLyricsInkHitView.inkBounds(in: panel.contentView, window: panel) else { return }
        let oldInk = panel.convertToScreen(originalInk)
        let offset = CGSize(width: oldInk.minX - projectedInk.minX,
                            height: projectedInk.minY - oldInk.minY)
        switch preset.cell.0 {
        case 0: model?.settings.floatingLyrics.textAlignment = .leading
        case 2: model?.settings.floatingLyrics.textAlignment = .trailing
        default: model?.settings.floatingLyrics.textAlignment = .center
        }
        UserDefaults.standard.set(preset.rawValue, forKey: LyricsPositionPreset.selectionKey)
        moveToPreset(target, animated: true, initialOffset: offset)
    }

    func nudgePosition(dx: CGFloat, dy: CGFloat) {
        guard let panel, transitionFrame == nil else { return }
        let defaults = UserDefaults.standard
        let hasPreset = LyricsPositionPreset(rawValue: defaults.string(forKey: LyricsPositionPreset.selectionKey) ?? "") != nil
        if hasPreset {
            defaults.set(defaults.double(forKey: presetOffsetXKey) + Double(dx), forKey: presetOffsetXKey)
            defaults.set(defaults.double(forKey: presetOffsetYKey) + Double(dy), forKey: presetOffsetYKey)
        }
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y += dy
        panel.setFrame(frame, display: true)
        DesktopFloatingLyricsFramePersistence.save(frame, window: panel, clearPreset: !hasPreset)
        cachedPresetFrames.removeAll()
        cachedPresetInk.removeAll()
    }

    // Cache targets after the text and screen geometry settle, before selection.
    func schedulePresetReposition() {
        pendingPresetReposition?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionFrame == nil else { return }
            self.pendingPresetReposition = nil
            self.captureReferencePositionIfNeeded()
            self.refreshPresetFrames()
            self.repositionSelectedPreset()
        }
        pendingPresetReposition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func refreshPresetFrames() {
        guard let panel, transitionFrame == nil, let screen = panel.screen ?? NSScreen.main,
              let localInk = DesktopFloatingLyricsInkHitView.inkBounds(in: panel.contentView, window: panel),
              let model else { return }
        let frame = panel.frame
        let scale = CGFloat(model.settings.floatingLyrics.fontScale)
        let glow = model.settings.floatingLyrics.textEffect == .glow
        let inset = glow ? max(14, min(30 * max(1, scale) * 2.5 + 4, max(14, frame.width * 0.18))) : 14
        let currentInk = panel.convertToScreen(localInk)
        let bottomInset = (UserDefaults.standard.object(forKey: bottomInsetKey) as? NSNumber)?.doubleValue ?? 12
        let topInset = (UserDefaults.standard.object(forKey: topCenterInsetKey) as? NSNumber)?.doubleValue ?? 50
        var frames: [LyricsPositionPreset: NSRect] = [:]
        var inks: [LyricsPositionPreset: NSRect] = [:]
        for preset in LyricsPositionPreset.allCases {
            let x = preset.cell.0
            var projected = currentInk
            projected.origin.x = x == 0 ? frame.minX + inset : x == 2 ? frame.maxX - inset - projected.width : frame.midX - projected.width / 2
            var target = frame
            if preset == .topLeft || preset == .topRight {
                target.origin.x = preset == .topLeft ? screen.visibleFrame.minX - 60 : screen.visibleFrame.maxX + 60 - frame.width
                target.origin.y = screen.frame.maxY + 9 - frame.height
            } else {
                let delta = preset.displacement(ink: projected, screen: screen.frame, visible: screen.visibleFrame,
                    topLimit: screen.frame.maxY - screen.safeAreaInsets.top,
                    bottomInset: CGFloat(bottomInset), topCenterInset: CGFloat(topInset) - 5)
                target.origin.x += delta.x; target.origin.y += delta.y
            }
            if preset.rawValue == UserDefaults.standard.string(forKey: LyricsPositionPreset.selectionKey) {
                target.origin.x += CGFloat(UserDefaults.standard.double(forKey: presetOffsetXKey))
                target.origin.y += CGFloat(UserDefaults.standard.double(forKey: presetOffsetYKey))
            }
            projected.origin.x += target.minX - frame.minX
            projected.origin.y += target.minY - frame.minY
            frames[preset] = target
            inks[preset] = projected
        }
        cachedPresetFrames = frames
        cachedPresetInk = inks
    }

    private func repositionSelectedPreset() {
        guard !DesktopFloatingLyricsFramePersistence.isUserAdjusting,
              let preset = LyricsPositionPreset(rawValue: UserDefaults.standard.string(forKey: LyricsPositionPreset.selectionKey) ?? ""),
              let panel, let target = cachedPresetFrames[preset] else { return }
        guard abs(target.minX - panel.frame.minX) > 0.5 || abs(target.minY - panel.frame.minY) > 0.5 else { return }
        guard panel.isVisible, isVisible, !autoHidden,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            moveToPreset(target, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
        DesktopFloatingLyricsFramePersistence.save(target, window: panel, clearPreset: false)
    }

    private func moveToPreset(_ target: NSRect, animated: Bool, initialOffset: CGSize? = nil) {
        guard let panel, let hosting = hostingView, let normalContainer,
              animated, panel.isVisible, isVisible, !autoHidden,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if let panel { panel.setFrame(target, display: true); DesktopFloatingLyricsFramePersistence.save(target, window: panel, clearPreset: false) }
            return
        }
        let original = panel.frame
        let bounds = original.union(target)
        generation += 1
        let token = generation
        transitionFrame = target
        let offset = initialOffset ?? CGSize(width: original.minX - target.minX, height: target.minY - original.minY)
        let order = CharacterScreenTransition.presetOrder(offsetX: offset.width)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            screenMotion.entering = true
            screenMotion.rightFirst = order.rightFirst
            screenMotion.centerFirst = order.centerFirst
            screenMotion.offset = offset
            screenMotion.progress = 0
            screenMotion.active = true
        }
        hosting.autoresizingMask = []
        panel.ignoresMouseEvents = true
        panel.setFrame(bounds, display: false)
        hosting.frame = NSRect(x: target.minX - bounds.minX, y: target.minY - bounds.minY,
                               width: target.width, height: target.height)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.generation == token else { return }
            withAnimation(.linear(duration: 0.8)) { self.screenMotion.progress = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            guard self.generation == token else { return }
            panel.setFrame(target, display: false)
            hosting.frame = normalContainer.bounds
            hosting.autoresizingMask = [.width, .height]
            self.transitionFrame = nil
            var cleanup = Transaction(animation: nil); cleanup.disablesAnimations = true
            withTransaction(cleanup) { self.screenMotion.active = false; self.screenMotion.progress = 1 }
            DesktopFloatingLyricsFramePersistence.save(target, window: panel, clearPreset: false)
            self.refreshPresetFrames()
            if let pending = self.pendingPreset {
                self.pendingPreset = nil
                self.applyPositionPreset(pending)
            }
            if let (width, alignment) = self.pendingWidth {
                self.pendingWidth = nil
                self.ensureLyricsWidth(width, alignment: alignment)
            }
        }
    }

    func setVisible(_ visible: Bool) { if visible { show() } else { hide() } }

    func ensureLyricsWidth(_ width: CGFloat, alignment: FloatingLyricsTextAlignment) {
        guard width.isFinite, width > 0, let panel else { return }
        if transitionFrame != nil { pendingWidth = (width, alignment); return }
        guard width > panel.frame.width + 1 else { return }
        var frame = panel.frame
        let extra = ceil(width) - frame.width
        if alignment == .trailing { frame.origin.x -= extra }
        else if alignment == .center { frame.origin.x -= extra / 2 }
        frame.size.width += extra
        panel.setFrame(frame, display: true)
        updateTravelDistance(for: panel)
    }

    func updateTravelDistance(for window: NSWindow) {
        guard window === panel, transitionFrame == nil else { return }
        screenMotion.offset = CGSize(width: 0, height: CharacterScreenTransition.displacement(
            for: window.frame, screens: NSScreen.screens.map(\.frame)))
    }

    func show() {
        guard let model else { return }
        if isVisible && !autoHidden && panel?.isVisible == true { return }
        if panel == nil {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = DesktopFloatingLyricsFramePersistence.savedFrame()
            ?? NSRect(x: screen.midX - 210, y: screen.midY - 66, width: 420, height: 132)
        // Reserve the same drawing area before, during and after movement.
        screenMotion.offset = CGSize(width: 0, height: CharacterScreenTransition.displacement(
            for: initial, screens: NSScreen.screens.map(\.frame)))
        let panel = UnconstrainedLyricsPanel(contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "悬浮歌词"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        // Follow desktops and full-screen Spaces without detecting or hiding for other apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 112)
        panel.isMovableByWindowBackground = false
        let container = NSView(frame: NSRect(origin: .zero, size: initial.size))
        container.clipsToBounds = false
        let hosting = NSHostingView(rootView: DesktopFloatingLyricsWindow(screenMotion: screenMotion).environment(model))
        hosting.sizingOptions = []
        hosting.clipsToBounds = false
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.normalContainer = container
        self.hostingView = hosting
        // Content installation is allowed to size its view, never to choose the position.
        panel.setFrame(initial, display: false)
        self.panel = panel
        }
        isVisible = true; autoHidden = false
        needsInitialLyricsAnimation = false
        animateCharacters(entering: true) { [weak self] in self?.schedulePresetReposition() }
        if lastPlaying == false { schedulePause() }
    }

    func firstLyricsAvailable() {
        guard needsInitialLyricsAnimation, isVisible, !autoHidden, model?.lyrics.lyrics.isEmpty == false else { return }
        needsInitialLyricsAnimation = false
        animateCharacters(entering: true) {}
    }

    func hide() {
        pendingPause?.cancel(); pendingPause = nil
        isVisible = false; autoHidden = false; needsInitialLyricsAnimation = false
        animateCharacters(entering: false) {}
    }

    func playbackChanged(_ playing: Bool) {
        guard lastPlaying != playing else { return }
        lastPlaying = playing
        pendingPause?.cancel(); pendingPause = nil
        if playing {
            if isVisible && autoHidden { autoHidden = false; animateCharacters(entering: true) {} }
        } else if isVisible { schedulePause() }
    }

    private func schedulePause() {
        pendingPause?.cancel()
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lastPlaying == false, self.isVisible else { return }
                self.pendingPause = nil; self.autoHidden = true
                self.animateCharacters(entering: false) {}
            }
        }
        pendingPause = task
        DispatchQueue.main.asyncAfter(deadline: .now() + CharacterScreenTransition.pauseDelay, execute: task)
    }

    private func animateCharacters(entering: Bool, completion: @escaping () -> Void) {
        guard let panel, let model, let hosting = hostingView, let normalContainer else { completion(); return }
        generation += 1
        let token = generation
        // A reversal keeps its current curve so its position does not jump.
        if transitionFrame == nil { screenMotion.entering = entering }
        let screens = NSScreen.screens.map(\.frame)
        guard let first = screens.first, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if let frame = transitionFrame {
                panel.setFrame(frame, display: false)
                hosting.frame = normalContainer.bounds
                hosting.autoresizingMask = [.width, .height]
                transitionFrame = nil
            }
            screenMotion.active = false; screenMotion.progress = 1
            if entering { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
            completion(); return
        }
        if transitionFrame == nil {
            let frame = panel.frame
            let bounds = screens.dropFirst().reduce(first) { $0.union($1) }.union(frame)
            let activeScreen = panel.screen?.frame ?? first
            let upward = frame.midY >= activeScreen.midY
            let relativeX = (frame.midX - activeScreen.minX) / max(1, activeScreen.width)
            let distance = CharacterScreenTransition.displacement(for: frame, screens: screens, upward: upward)
            var preparation = Transaction(animation: nil)
            preparation.disablesAnimations = true
            withTransaction(preparation) {
                screenMotion.offset = CGSize(width: 0, height: distance)
                screenMotion.rightFirst = relativeX > 0.6
                screenMotion.centerFirst = relativeX >= 0.4 && relativeX <= 0.6
                screenMotion.progress = entering ? 0 : 1
                screenMotion.active = true
            }
            // Keep the same hosting view in the same window. Expanding its
            // surface provides room for the animation without reparenting it.
            transitionFrame = frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosting.autoresizingMask = []
            panel.ignoresMouseEvents = true
            panel.setFrame(bounds, display: false)
            hosting.frame = NSRect(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY,
                                   width: frame.width, height: frame.height)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            panel.orderFrontRegardless()
            CATransaction.commit()
        }
        // Give SwiftUI a display cycle to present the prepared starting frame.
        // Reversals keep the existing presentation instead of resetting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.generation == token else { return }
            withAnimation(.linear(duration: CharacterScreenTransition.duration)) {
                self.screenMotion.progress = entering ? 1 : 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CharacterScreenTransition.duration + 0.15) {
            guard self.generation == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !entering || !self.isVisible || self.autoHidden { panel.orderOut(nil) }
            if let frame = self.transitionFrame {
                panel.setFrame(frame, display: false)
                hosting.frame = normalContainer.bounds
                hosting.autoresizingMask = [.width, .height]
            }
            self.transitionFrame = nil
            var cleanup = Transaction(animation: nil)
            cleanup.disablesAnimations = true
            withTransaction(cleanup) {
                self.screenMotion.active = false
                self.screenMotion.progress = 1
            }
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if entering && self.isVisible && !self.autoHidden { panel.orderFrontRegardless() }
            if let (width, alignment) = self.pendingWidth {
                self.pendingWidth = nil
                self.ensureLyricsWidth(width, alignment: alignment)
            }
            CATransaction.commit()
            completion()
            if entering, let pending = self.pendingPreset {
                self.pendingPreset = nil
                self.refreshPresetFrames()
                self.applyPositionPreset(pending)
            }
        }
    }

    func prepareToTerminate(_ completion: @escaping () -> Void) -> Bool {
        pendingPause?.cancel(); pendingPause = nil
        guard isVisible, !autoHidden, panel != nil else { return false }
        isVisible = false; needsInitialLyricsAnimation = false
        animateCharacters(entering: false, completion: completion)
        return true
    }
}

@MainActor final class FlowflowDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FloatingLyricsWindowController.shared.show()
        FlowflowAutoStart.install()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        FloatingLyricsWindowController.shared.show()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let animated = FloatingLyricsWindowController.shared.prepareToTerminate {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return animated ? .terminateLater : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
