import SwiftUI
import AppKit

func playbackControlSymbolWeight(_ symbol: String) -> Font.Weight {
    symbol == "plus" || symbol == "minus" ? .bold : .semibold
}

struct DesktopFloatingLyricsWindow: View {
    @Environment(DesktopAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("floatingLyrics.hoverControls") private var hoverControls = true
    @State private var hovering = false
    @AppStorage("floatingLyrics.readabilityStrength") private var readabilityStrength = 0.5
    @AppStorage("floatingLyrics.projectionStrength") private var projectionStrength = 0.45
    @AppStorage("floatingLyrics.blackOutline") private var blackOutline = false
    @AppStorage("floatingLyrics.characterFloat") private var characterFloat = true
    @AppStorage("floatingLyrics.floatAmplitude") private var floatAmplitude = 6.0
    @AppStorage("floatingLyrics.artworkColorEnabled") private var artworkColorEnabled = true
    @AppStorage("floatingLyrics.customColorEnabled") private var customColorEnabled = false
    @AppStorage("floatingLyrics.colorRed") private var colorRed = 1.0
    @AppStorage("floatingLyrics.colorGreen") private var colorGreen = 1.0
    @AppStorage("floatingLyrics.colorBlue") private var colorBlue = 1.0
    var screenMotion: ScreenCharacterMotion? = nil
    var menuPreview = false
    init(screenMotion: ScreenCharacterMotion? = nil, menuPreview: Bool = false) {
        self.screenMotion = screenMotion
        self.menuPreview = menuPreview
    }
    @State private var playbackProgress: TimeInterval = 0
    @State private var floatMotion = false
    @State private var floatClockRunning = false

    private var position: LyricPlaybackPosition {
        LyricPlaybackTimeline.position(
            at: playbackProgress,
            in: model.lyrics.lyrics
        )
    }

    private var currentIndex: Int? {
        guard let id = position.highlightedLyricID else { return nil }
        return model.lyrics.lyrics.firstIndex { $0.id == id }
    }

    private var currentLine: LyricLine? {
        model.lyrics.heldLine ?? currentIndex.map { model.lyrics.lyrics[$0] }
    }

    private var showsSongInformation: Bool {
        guard model.player.currentSong != nil else { return false }
        if model.lyrics.isPureMusic || model.lyrics.hasNoLyrics { return true }
        let lines = model.lyrics.lyrics
        return !lines.isEmpty && lines.allSatisfy {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "..." || LyricsQuality.isInstrumentalText(text)
        }
    }

    private var showsInstrumentalDots: Bool {
        if model.lyrics.heldLine != nil { return false }
        if model.lyrics.isPureMusic { return true }
        guard let line = currentLine else { return true }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "..." || LyricsQuality.isInstrumentalText(text) || text == L10n.string("ui.lyrics.instrumental")
            || text == "纯音乐，请欣赏" || text == "纯音乐，请欣赏！" {
            return true
        }
        // Only use authored/inferred end times; never guess a singing gap
        // from the distance between two LRC timestamps.
        let end = ([line.duration.flatMap { $0 > 0 ? line.time + $0 : nil }]
            + line.syllables.map { Optional($0.endTime) })
            .compactMap { $0 }.filter { $0.isFinite }.max()
        guard let end, playbackProgress >= end + 0.25 else { return false }
        if let index = currentIndex, model.lyrics.lyrics.indices.contains(index + 1) {
            return LyricGapPolicy.shouldShowDots(end: end, next: model.lyrics.lyrics[index + 1].time, now: playbackProgress)
        }
        return true
    }

    private var fontScale: CGFloat {
        CGFloat(model.settings.floatingLyrics.fontScale)
    }

    private var preferences: FloatingLyricsPreferences {
        model.settings.floatingLyrics
    }

    private var textAlignment: TextAlignment {
        switch model.settings.floatingLyrics.textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch preferences.textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var primaryTextColor: Color {
        if SongColorOverride.isGoldenHour(model.player.currentSong) {
            return Color(red: 1, green: 161.0 / 255.0, blue: 60.0 / 255.0)
        }
        if artworkColorEnabled { return model.artworkColor ?? (preferences.backgroundStyle.usesLightForeground ? .white : .primary) }
        return customColorEnabled ? Color(red: colorRed, green: colorGreen, blue: colorBlue) : (preferences.backgroundStyle.usesLightForeground ? .white : .primary)
    }

    private var textShadowColor: Color {
        switch preferences.textEffect {
        case .none:
            .clear
        case .shadow:
            .black.opacity(0.62)
        case .glow:
            primaryTextColor.opacity(min(1, 0.48 * preferences.glowIntensity))
        }
    }

    private var textShadowRadius: CGFloat {
        switch preferences.textEffect {
        case .none: 0
        case .shadow: 3
        case .glow: CGFloat(preferences.glowRadius)
        }
    }

    // A tighter inner halo keeps brighter glow visible without blurring the glyphs.
    private var glowCoreColor: Color {
        preferences.textEffect == .glow
            ? primaryTextColor.opacity(min(1, 0.30 * preferences.glowIntensity))
            : .clear
    }

    private var textShadowOffset: CGFloat {
        preferences.textEffect == .shadow ? 1 : 0
    }

    private var projectionColor: Color {
        Color(nsColor: NSColor(primaryTextColor).blended(withFraction: 0.82, of: .black) ?? .black)
    }
    private var projectionOpacity: Double { min(1, max(0, projectionStrength)) }

    var body: some View {
        Group {
            if menuPreview {
                lyricsContent
                    .onChange(of: model.player.progress, initial: true) { _, _ in playbackProgress = model.player.estimatedProgress() }
                    .onChange(of: model.player.currentSong?.id, initial: true) { _, _ in playbackProgress = model.player.estimatedProgress() }
            } else {
                floatingBody
            }
        }
        .task(id: model.player.isPlaying) {
            if model.player.isPlaying {
                floatClockRunning = true
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { floatMotion = true }
            } else {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { floatMotion = false }
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { return }
                floatClockRunning = false
            }
        }
    }

    private var floatingBody: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .accessibilityHidden(true)

            lyricsContent
                .opacity(hoverControls && hovering ? 0 : 1)
                .allowsHitTesting(false)

            if screenMotion?.active != true {
                DesktopFloatingLyricsInteraction()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hoverControls {
                    GeometryReader { geometry in
                        HStack(spacing: 16) {
                            hoverActionButton("minus", label: "歌词延后 0.1 秒") { model.player.adjustOffset(by: -0.1) }
                            hoverPlaybackButton("backward.end.fill", label: "上一首", command: 5)
                            hoverPlaybackButton(model.playbackControlIsPlaying ? "pause.fill" : "play.fill", label: model.playbackControlIsPlaying ? "暂停" : "播放", command: 2)
                            hoverPlaybackButton("forward.end.fill", label: "下一首", command: 4)
                            hoverActionButton("plus", label: "歌词提前 0.1 秒") { model.player.adjustOffset(by: 0.1) }
                        }
                        .buttonStyle(.plain)
                        .background { softDarkBackdrop.opacity(hovering ? 1 : 0) }
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        .padding(.horizontal, glowSafeInset(length: geometry.size.width, minimum: 14, fraction: 0.18))
                        .padding(.top, glowSafeInset(length: geometry.size.height, minimum: 32, fraction: 0.22))
                        .padding(.bottom, glowSafeInset(length: geometry.size.height, minimum: 18, fraction: 0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: hoverControls && hovering)
        .frame(minWidth: 300, minHeight: 112)
        .contentShape(.rect)
        .task(id: "\(currentLine?.text ?? "")|\(currentLine?.translation ?? "")|\(preferences.fontFamily)|\(fontScale)|\(preferences.textAlignment.rawValue)|\(preferences.showsTranslation)|\(preferences.showsNextLine)|\(model.player.currentSong?.id ?? "")|\(showsSongInformation)") {
            let font = NSFont(name: preferences.fontFamily, size: 26 * fontScale)
                ?? NSFont.systemFont(ofSize: 26 * fontScale, weight: .bold)
            var strings = visibleLyricRows.map { $0.line.text }
            if showsSongInformation, let song = model.player.currentSong { strings += [song.name, song.artist] }
            if preferences.showsTranslation, let translation = currentLine?.translation { strings.append(translation) }
            let widest = strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            // Reserve space for the glow and font-metric differences across scripts.
            let margin = max(64, CGFloat(FloatingLyricsPreferences.glowRadiusRange.upperBound) * max(1, fontScale) * 5 + 16)
            FloatingLyricsWindowController.shared.ensureLyricsWidth(widest * 1.15 + margin, alignment: preferences.textAlignment)
            FloatingLyricsWindowController.shared.schedulePresetReposition()
        }
        .task(id: "\(artworkColorEnabled)|\(model.player.currentSong?.id ?? "")") {
            // Keep the last successful color while the next cover loads.
            guard artworkColorEnabled, let song = model.player.currentSong,
                  !SongColorOverride.isGoldenHour(song) else { return }
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                guard !Task.isCancelled else { return }
                if let rgb = await ArtworkLyricColor.load(for: song) {
                    guard !Task.isCancelled, artworkColorEnabled, model.player.currentSong?.id == song.id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                        model.artworkColor = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
                    }
                    return
                }
            }
        }
        // `estimatedProgress()` only reads the playback timeline clock, so
        // SwiftUI observation never sees `PlayerStore.progress` mutate when
        // this window is the only observer. Mirror the published sample into
        // a local state so the current line advances with the engine clock.
        .onChange(of: model.player.progress, initial: true) { _, _ in
            playbackProgress = model.player.estimatedProgress()
        }
        .onChange(of: model.player.currentSong?.id, initial: true) { _, _ in
            playbackProgress = model.player.estimatedProgress()
        }
        .background {
            if screenMotion?.active != true {
            DesktopFloatingLyricsWindowConfiguration(hovering: $hovering, controlsEnabled: hoverControls)
                .allowsHitTesting(false)
            }
        }
    }

    private func hoverPlaybackButton(_ symbol: String, label: String, command: Int) -> some View {
        hoverActionButton(symbol, label: label) { model.sendPlaybackCommand(command) }
    }

    private func hoverActionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        HoverPlaybackButton(symbol: symbol, label: label, color: primaryTextColor,
            opacity: preferences.textOpacity, controlsVisible: hovering, glowIntensity: preferences.textEffect == .glow ? preferences.glowIntensity : 0,
            glowRadius: CGFloat(preferences.glowRadius) * fontScale, fontScale: fontScale,
            projectionColor: projectionColor, projectionOpacity: projectionOpacity,
            shadowOpacity: preferences.textEffect == .shadow ? 0.62 : readabilityShadow,
            reduceMotion: reduceMotion, action: action)
    }

    private var lyricsContent: some View {
        GeometryReader { geometry in
        ZStack {
            // Empty, loading, unavailable and instrumental states share the dots.
            // Connection/error details remain in settings and the menu, never the overlay.
            if showsSongInformation, let song = model.player.currentSong {
                let line = LyricLine(time: 0, text: song.name,
                    translation: song.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : song.artist)
                ZStack {
                    if !menuPreview {
                        lyricRow(line: line, isFocused: true, forceTranslation: true, backgroundOnly: true)
                            .accessibilityHidden(true).allowsHitTesting(false)
                        lyricRow(line: line, isFocused: true, forceTranslation: true, projectionOnly: true)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                    lyricRow(line: line, isFocused: true, forceTranslation: true, glowOnly: true)
                        .accessibilityHidden(true).allowsHitTesting(false)
                    lyricRow(line: line, isFocused: true, forceTranslation: true)
                }
                    .transition(lyricsSwapTransition)
            } else if showsInstrumentalDots {
                FloatingLyricsWaitingDots(
                    diameter: max(12, 18 * fontScale),
                    color: primaryTextColor.opacity(preferences.textOpacity),
                    outline: blackOutline,
                    outlineOpacity: readabilityOutline,
                    readabilityShadow: readabilityShadow,
                    animates: floatMotion && !reduceMotion,
                    screenProgress: screenMotion?.progress ?? 1,
                    screenDistance: screenMotion?.offset.height ?? 0,
                    entering: screenMotion?.entering ?? true,
                    rightFirst: screenMotion?.rightFirst ?? false,
                    centerFirst: screenMotion?.centerFirst ?? false
                )
                .shadow(color: projectionColor.opacity(menuPreview ? 0 : projectionOpacity), radius: 2.5 * fontScale, y: 1.5 * fontScale)
                .shadow(color: textShadowColor, radius: preferences.textEffect == .glow ? CGFloat(preferences.glowRadius) * fontScale : textShadowRadius, y: textShadowOffset)
                .shadow(color: glowCoreColor, radius: CGFloat(preferences.glowRadius) * fontScale * 0.28)
                .background { if !menuPreview { softDarkBackdrop } }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .transition(lyricsSwapTransition)
            } else {
                ZStack {
                    if !menuPreview {
                        lyricRows(backgroundOnly: true)
                            .accessibilityHidden(true).allowsHitTesting(false)
                        lyricRows(backgroundOnly: false, projectionOnly: true)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                    lyricRows(backgroundOnly: false, glowOnly: true)
                        .accessibilityHidden(true).allowsHitTesting(false)
                    lyricRows(backgroundOnly: false)
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .transition(lyricsSwapTransition)
            }
        }
        // Reserve space inside the actual window surface for the glow. The
        // limits preserve usable room for lyrics in a small window.
        .padding(.horizontal, menuPreview ? 8 : glowSafeInset(length: geometry.size.width, minimum: 14, fraction: 0.18))
        .padding(.top, menuPreview ? 8 : glowSafeInset(length: geometry.size.height, minimum: 32, fraction: 0.22))
        .padding(.bottom, menuPreview ? 8 : glowSafeInset(length: geometry.size.height, minimum: 18, fraction: 0.22))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: primaryTextColor)
        .animation(reduceMotion ? nil : (preferences.showsNextLine ? .timingCurve(0.65, 0, 0.34, 1.22, duration: 0.48) : .easeOut(duration: 0.20)), value: currentLine?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: showsInstrumentalDots)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: showsSongInformation)
    }

    private func lyricRows(backgroundOnly: Bool, glowOnly: Bool = false, projectionOnly: Bool = false) -> some View {
        StableLyricRowsLayout(activeIDs: visibleLyricRows.map(\.id), spacing: CGFloat(preferences.lineSpacing)) {
            ForEach(visibleLyricRows) { row in
                lyricRow(line: row.line, isFocused: row.isFocused, backgroundOnly: backgroundOnly, glowOnly: glowOnly, projectionOnly: projectionOnly)
                    .layoutValue(key: LyricRowIDKey.self, value: row.id)
                    .layoutValue(key: LyricRowFocusKey.self, value: row.isFocused)
                    .transition(!preferences.showsNextLine && !reduceMotion && !sharedIndices(for: row.line).isEmpty
                                ? .asymmetric(insertion: .identity, removal: .opacity) : lyricRowTransition)
                    .zIndex(row.isFocused ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private func glowSafeInset(length: CGFloat, minimum: CGFloat, fraction: CGFloat) -> CGFloat {
        guard preferences.textEffect == .glow else { return minimum }
        // Reserve a stable maximum glow margin so changing its radius cannot
        // move the lyrics or alter their window width.
        let radius = CGFloat(FloatingLyricsPreferences.glowRadiusRange.upperBound) * max(1, fontScale)
        return max(minimum, min(radius * 2.5 + 4, max(minimum, length * fraction)))
    }

    private var lyricsSwapTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        guard preferences.showsNextLine else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .offset(y: -8).combined(with: .opacity)
        )
    }

    private var visibleLyricRows: [FloatingLyricRow] {
        if let held = model.lyrics.heldLine { return [FloatingLyricRow(line: held, isFocused: true)] }
        guard let index = currentIndex else { return [] }
        var rows = [FloatingLyricRow(line: model.lyrics.lyrics[index], isFocused: true)]
        if preferences.showsNextLine, model.lyrics.lyrics.indices.contains(index + 1) {
            let next = model.lyrics.lyrics[index + 1]
            if next.text != "..." && !LyricsQuality.isInstrumentalText(next.text) {
                rows.append(FloatingLyricRow(line: next, isFocused: false))
            }
        }
        return rows
    }

    private var lyricRowTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        guard preferences.showsNextLine else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 18).combined(with: .opacity),
            removal: .offset(y: -56 * fontScale).combined(with: .opacity)
                .animation(.easeOut(duration: 0.16))
        )
    }

    private var safeReadability: Double { min(1, max(0, readabilityStrength)) }
    private var readabilityShadow: Double { max(0, safeReadability - 0.5) * 0.6 }
    private var readabilityOutline: Double { 0.08 + max(0, safeReadability - 0.5) * 0.24 }

    private var softDarkBackdrop: some View {
        let spread = max(8, CGFloat(preferences.glowRadius) * fontScale)
        let fade = max(8, spread * 1.5)
        let textColor = NSColor(primaryTextColor).usingColorSpace(.deviceRGB)
        let isBrightGreen = textColor.map {
            $0.hueComponent >= 0.22 && $0.hueComponent <= 0.48
                && $0.saturationComponent >= 0.35 && $0.brightnessComponent >= 0.65
        } ?? false
        let isWhite = textColor.map { $0.saturationComponent < 0.12 && $0.brightnessComponent > 0.85 } ?? false
        let backdropColor: NSColor = if isBrightGreen, let textColor {
            NSColor(calibratedHue: textColor.hueComponent, saturation: 0.75, brightness: 0.12, alpha: 1)
        } else if isWhite {
            .black
        } else {
            NSColor(primaryTextColor).blended(withFraction: 0.78, of: .black) ?? .black
        }
        return Capsule()
            .fill(Color(nsColor: backdropColor)
                .opacity(safeReadability * (isBrightGreen || isWhite ? 0.90 : 0.60)))
            .padding(.horizontal, -spread)
            .padding(fade * 2)
            .blur(radius: fade)
            .padding(-fade * 2)
            .background {
                LyricSystemBlur()
                    .padding(.horizontal, -spread * 2)
                    .padding(.vertical, -max(12, spread))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func lyricRow(line: LyricLine, isFocused: Bool, forceTranslation: Bool = false, backgroundOnly: Bool = false, glowOnly: Bool = false, projectionOnly: Bool = false) -> some View {
        // Build attributed text once per row update, outside the display clock.
        let preparedText = timedText(for: line, preserveShared: isFocused && !preferences.showsNextLine && !reduceMotion)
        let animates = (floatClockRunning && characterFloat && !reduceMotion)
            || (model.player.isPlaying && isFocused && !line.syllables.isEmpty)
        let lyricTime = model.lyrics.heldLine?.id == line.id ? model.lyrics.heldTime : model.player.estimatedProgress()
        let scale: CGFloat = isFocused ? 1 : 17.0 / 26.0
        let anchor = UnitPoint(x: textAlignment == .leading ? 0 : textAlignment == .trailing ? 1 : 0.5, y: 0)
        return VStack(alignment: .leading, spacing: preferences.lineSpacing) {
            if preferences.showsNextLine && !forceTranslation {
                translationRow(line: line, isFocused: isFocused, forceTranslation: forceTranslation, animates: animates,
                               backgroundOnly: backgroundOnly, glowOnly: glowOnly, projectionOnly: projectionOnly)
            }
            ScaledLyricLayout(scale: scale) {
            TimelineView(.animation(minimumInterval: 1.0 / 60,
                                    paused: !animates)) { context in
                preparedText
                    // Shape and wrap once at the final size; animate its transform.
                    .font(LyricsFontFamily.font(preferences.fontFamily, size: 26 * fontScale,
                                               weight: preferences.fontWeight.swiftUIWeight))
                    .foregroundStyle(primaryTextColor.opacity(preferences.textOpacity))
                    .textRenderer(FloatingCharacterRenderer(
                        time: lyricTime,
                        amplitude: characterFloat && !reduceMotion && floatMotion ? CGFloat(min(6, max(0, floatAmplitude))) * fontScale : 0,
                        motionTime: context.date.timeIntervalSinceReferenceDate,
                        screenProgress: screenMotion?.progress ?? 1,
                        screenOffset: screenMotion?.offset ?? .zero,
                        screenAnimating: screenMotion?.active == true,
                        entering: screenMotion?.entering ?? true,
                        rightFirst: screenMotion?.rightFirst ?? false,
                    centerFirst: screenMotion?.centerFirst ?? false,
                        glowColor: primaryTextColor,
                        glowRadius: CGFloat(preferences.glowRadius) * fontScale,
                        glowIntensity: preferences.textEffect == .glow ? preferences.glowIntensity : 0,
                        dimCompletedLyrics: preferences.dimCompletedLyrics,
                        outlineWidth: blackOutline ? max(0.5, 0.7 * fontScale) : 0,
                        outlineOpacity: readabilityOutline,
                        readabilityShadow: readabilityShadow,
                        projectionColor: projectionColor, projectionOpacity: projectionOpacity,
                        projectionOnly: projectionOnly,
                        glowOnly: glowOnly,
                        drawsGlow: glowOnly,
                        focus: isFocused ? 1 : 0))
                    .animation(reduceMotion || screenMotion?.active == true ? nil : .easeInOut(duration: 0.7), value: floatMotion)
                    .animation(reduceMotion || screenMotion?.active == true ? nil : .easeInOut(duration: 0.7), value: characterFloat)
                    .lineLimit(menuPreview ? 2 : 1)
                    .fixedSize(horizontal: !menuPreview, vertical: menuPreview)
                    .multilineTextAlignment(textAlignment)
                    .shadow(color: !glowOnly && !projectionOnly && preferences.textEffect == .shadow ? textShadowColor : .clear,
                            radius: textShadowRadius, y: textShadowOffset)
                    .opacity(backgroundOnly ? 0 : 1)
                    .background { if backgroundOnly { softDarkBackdrop } }
                    .background {
                        if !backgroundOnly && !glowOnly && !projectionOnly {
                            lyricsInkRegion(line.text, size: (isFocused ? 26 : 17) * fontScale,
                                            weight: preferences.fontWeight.swiftUIWeight, lines: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
            .scaleEffect(scale, anchor: anchor)
            }
            if !(preferences.showsNextLine && !forceTranslation) {
                translationRow(line: line, isFocused: isFocused, forceTranslation: forceTranslation, animates: animates,
                               backgroundOnly: backgroundOnly, glowOnly: glowOnly, projectionOnly: projectionOnly)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private func translationRow(line: LyricLine, isFocused: Bool, forceTranslation: Bool, animates: Bool,
                                backgroundOnly: Bool, glowOnly: Bool, projectionOnly: Bool) -> some View {
            if isFocused, (preferences.showsTranslation || forceTranslation), let translation = line.translation,
               !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animates)) { context in
                motionText(translation, time: line.time)
                    .font(LyricsFontFamily.font(preferences.fontFamily, size: 14 * fontScale, weight: .medium))
                    .foregroundStyle(primaryTextColor.opacity(preferences.textOpacity * FloatingLyricsTone.unplayedOpacity))
                    .textRenderer(FloatingCharacterRenderer(time: model.lyrics.heldLine?.id == line.id ? model.lyrics.heldTime : model.player.estimatedProgress(),
                        amplitude: characterFloat && !reduceMotion && floatMotion ? CGFloat(min(6, max(0, floatAmplitude))) * fontScale : 0,
                        motionTime: context.date.timeIntervalSinceReferenceDate,
                        screenProgress: screenMotion?.progress ?? 1, screenOffset: screenMotion?.offset ?? .zero,
                        screenAnimating: screenMotion?.active == true,
                        entering: screenMotion?.entering ?? true,
                        rightFirst: screenMotion?.rightFirst ?? false,
                        centerFirst: screenMotion?.centerFirst ?? false,
                        glowColor: primaryTextColor, glowRadius: CGFloat(preferences.glowRadius) * fontScale,
                        glowIntensity: preferences.textEffect == .glow ? preferences.glowIntensity : 0,
                        dimCompletedLyrics: false, outlineWidth: blackOutline ? max(0.5, 0.5 * fontScale) : 0,
                        outlineOpacity: readabilityOutline, readabilityShadow: readabilityShadow,
                        projectionColor: projectionColor, projectionOpacity: projectionOpacity,
                        projectionOnly: projectionOnly,
                        glowOnly: glowOnly, drawsGlow: glowOnly))
                    .lineLimit(menuPreview ? 2 : 1)
                    .fixedSize(horizontal: !menuPreview, vertical: menuPreview)
                    .multilineTextAlignment(textAlignment)
                    .shadow(color: !glowOnly && !projectionOnly && preferences.textEffect == .shadow ? textShadowColor : .clear,
                            radius: textShadowRadius, y: textShadowOffset)
                    .opacity(backgroundOnly ? 0 : 1)
                    .background { if backgroundOnly { softDarkBackdrop } }
                    .background {
                        if !backgroundOnly && !glowOnly && !projectionOnly {
                            lyricsInkRegion(translation, size: 14 * fontScale, weight: .medium, lines: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .transition(.opacity.animation(.easeIn(duration: 0.12).delay(0.03)))
                }
            } else if isFocused && !forceTranslation && preferences.showsTranslation && model.lyrics.hasTranslations {
                // Keep the same row height when only some lines have translations.
                Text("字")
                    .font(LyricsFontFamily.font(preferences.fontFamily, size: 14 * fontScale, weight: .medium))
                    .lineLimit(1)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .overlay(alignment: frameAlignment) {
                        if !backgroundOnly && !glowOnly && !projectionOnly {
                            DesktopFloatingLyricsLayoutAnchor().frame(width: 1)
                        }
                    }
                    .accessibilityHidden(true)
            }
    }

    private func motionText(_ value: String, time: TimeInterval) -> Text {
        LyricHighlightUnits.untimedMotionUnits(value).enumerated().reduce(Text("")) { text, pair in
            text + Text(pair.element).customAttribute(LyricCharacterTiming(start: time, end: time, phaseIndex: pair.offset))
        }
    }

    private func timedText(for line: LyricLine?, preserveShared: Bool = false) -> Text {
        guard let line else { return Text("") }
        let units = LyricHighlightUnits.make(for: line)
        let parts = units.isEmpty ? LyricHighlightUnits.untimedMotionUnits(line.text) : units.map(\.text)
        let retained = preserveShared ? sharedIndices(for: line) : []
        guard !units.isEmpty else {
            // Keep line-level timing, but give each character or word a separate
            // animation phase so untimed lines do not move as one block.
            return parts.enumerated().reduce(Text("")) { text, pair in
                text + Text(pair.element).customAttribute(LyricCharacterTiming(
                    start: line.time, end: line.time, phaseIndex: pair.offset))
                    .customAttribute(LyricChangeFade(start: line.time, fades: !retained.isEmpty && !retained.contains(pair.offset)))
            }
        }
        return units.enumerated().reduce(Text("")) { text, pair in
            let unit = pair.element
            return text + Text(unit.text).customAttribute(LyricCharacterTiming(
                start: unit.start, end: unit.end, phaseIndex: pair.offset))
                .customAttribute(LyricChangeFade(start: line.time, fades: !retained.isEmpty && !retained.contains(pair.offset)))
        }
    }

    private func sharedIndices(for line: LyricLine) -> Set<Int> {
        guard let index = model.lyrics.lyrics.firstIndex(where: { $0.id == line.id }), index > 0 else { return [] }
        func parts(_ line: LyricLine) -> [String] {
            let units = LyricHighlightUnits.make(for: line)
            return units.isEmpty ? LyricHighlightUnits.untimedMotionUnits(line.text) : units.map(\.text)
        }
        return LyricSharedText.match(parts(model.lyrics.lyrics[index - 1]), parts(line))
    }


    private func lyricsInkRegion(_ text: String, size: CGFloat,
                                 weight: Font.Weight, lines: Int) -> some View {
        DesktopFloatingLyricsInkHitRegion()
    }


}


enum LyricGapPolicy {
    static func shouldShowDots(end: TimeInterval, next: TimeInterval, now: TimeInterval) -> Bool {
        next - end > 5 && now - end > 5 && now < next
    }
}

enum SongColorOverride {
    static func isGoldenHour(_ song: Song?) -> Bool {
        guard let song else { return false }
        let title = song.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title == "golden hour" && artist == "jvke"
    }
}

enum FloatingLyricsTone {
    static let unplayedOpacity = 0.38
    static func bloomGain(intensity: Double) -> Double {
        min(1, max(0, (intensity - 3) / 3))
    }

    static func completedGlowMultiplier(currentStrength: Double) -> Double {
        1 - 0.7 * sqrt(min(1, max(0, currentStrength)))
    }

    static func dimmingStrength(for timing: LyricCharacterTiming, among timings: [LyricCharacterTiming], at time: TimeInterval) -> Double {
        let completed = timing.completedDimming(at: time)
        let later = timings.reduce(0.0) { maximum, candidate in
            guard candidate.start >= timing.end - 0.001,
                  candidate.start > timing.start,
                  candidate.end - candidate.start > 0.4 else { return maximum }
            return max(maximum, candidate.retainedDimmingStrength(at: time))
        }
        return completed * (0.35 + 0.65 * later)
    }

    static func completedOpacityMultiplier(currentStrength: Double) -> Double {
        0.4 + 0.6 * completedGlowMultiplier(currentStrength: currentStrength)
    }

    static func glowOpacity(sung: Double, sustained: Double, intensity: Double, focus: Double, core: Bool) -> Double {
        // Cap the residual glow separately so strong user settings cannot make
        // completed and currently sustained words equally opaque.
        let residual = min(core ? 0.48 : 0.58, max(0, intensity) * (core ? 0.16 : 0.22))
        let extra = min(0.14, max(0, intensity - 3) * (0.14 / 3))
        let base = (residual + extra) * sung
        let active = min(1, max(0, intensity) * (core ? 0.48 : 0.65)) * sustained
        return min(1, max(0, (base + active) * focus))
    }
}

private struct FloatingLyricRow: Identifiable {
    let line: LyricLine
    let isFocused: Bool
    var id: LyricLine.ID { line.id }
}

private struct LyricRowIDKey: LayoutValueKey {
    static let defaultValue = ""
}
private struct LyricRowFocusKey: LayoutValueKey {
    static let defaultValue = true
}

/// Retiring rows keep animating, but never add height to the active lyric stack.
private struct StableLyricRowsLayout: Layout {
    let activeIDs: [String]
    let spacing: CGFloat

    private func measurements(_ subviews: Subviews, proposal: ProposedViewSize) -> [(String, CGSize)] {
        activeIDs.compactMap { id in
            guard let view = subviews.first(where: { $0[LyricRowIDKey.self] == id }) else { return nil }
            return (id, view.sizeThatFits(proposal))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = measurements(subviews, proposal: proposal)
        return CGSize(width: proposal.width ?? rows.map { $0.1.width }.max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.1.height } + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        let rows = measurements(subviews, proposal: rowProposal)
        var positions: [String: CGFloat] = [:]
        var y = bounds.minY
        for (id, size) in rows { positions[id] = y; y += size.height + spacing }
        for view in subviews {
            let priorPosition = view[LyricRowFocusKey.self] ? bounds.minY : bounds.minY + (rows.first?.1.height ?? 0) + spacing
            view.place(at: CGPoint(x: bounds.minX, y: positions[view[LyricRowIDKey.self]] ?? priorPosition),
                       anchor: .topLeading, proposal: rowProposal)
        }
    }
}

/// The glyph layout stays at its final size while the compositor scales it.
/// Only the occupied row height changes, keeping the next row's scroll continuous.
private struct ScaledLyricLayout: Layout {
    var scale: CGFloat
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let size = text.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        text.place(at: bounds.origin, anchor: .topLeading,
                   proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

private struct HoverPlaybackButton: View {
    let symbol: String
    let label: String
    let color: Color
    let opacity: Double
    let controlsVisible: Bool
    let glowIntensity: Double
    let glowRadius: CGFloat
    let fontScale: CGFloat
    let projectionColor: Color
    let projectionOpacity: Double
    let shadowOpacity: Double
    let reduceMotion: Bool
    let action: () -> Void
    @State private var isHovered = false
    @State private var dragStartMouse: NSPoint?
    @State private var dragStartFrame: NSRect?
    @State private var didDrag = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: max(20, 24 * fontScale), weight: playbackControlSymbolWeight(symbol)))
                .foregroundStyle(color.opacity(controlsVisible ? opacity * (isHovered ? 1 : FloatingLyricsTone.unplayedOpacity) : 0))
                .shadow(color: projectionColor.opacity(controlsVisible ? projectionOpacity * opacity : 0), radius: 2.5 * fontScale, y: 1.5 * fontScale)
                .shadow(color: .black.opacity(controlsVisible ? shadowOpacity * opacity : 0), radius: 2 * fontScale, y: 0.5 * fontScale)
                .shadow(color: color.opacity(isHovered ? min(1, glowIntensity * 0.22) * opacity : 0), radius: glowRadius)
                .shadow(color: color.opacity(isHovered ? min(1, glowIntensity * 0.16) * opacity : 0), radius: glowRadius * 0.28)
                .frame(width: max(20, 24 * fontScale), height: max(20, 24 * fontScale))
                .contentShape(Rectangle())
                .background { DesktopHoverControlRegion() }
        }
        .allowsHitTesting(controlsVisible)
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard let window = NSApp.windows.first(where: { $0.title == "悬浮歌词" }) else { return }
                if dragStartMouse == nil {
                    dragStartMouse = NSEvent.mouseLocation
                    dragStartFrame = window.frame
                    didDrag = false
                }
                if hypot(value.translation.width, value.translation.height) >= 4 { didDrag = true }
                guard didDrag, !UserDefaults.standard.bool(forKey: "floatingLyrics.fixedPosition"),
                      let start = dragStartMouse, var frame = dragStartFrame else { return }
                DesktopFloatingLyricsFramePersistence.isUserAdjusting = true
                let mouse = NSEvent.mouseLocation
                frame.origin.x += mouse.x - start.x
                frame.origin.y += mouse.y - start.y
                window.setFrame(frame, display: true)
            }
            .onEnded { _ in
                if didDrag {
                    if DesktopFloatingLyricsFramePersistence.isUserAdjusting,
                       let window = NSApp.windows.first(where: { $0.title == "悬浮歌词" }) {
                        DesktopFloatingLyricsFramePersistence.save(window.frame, window: window)
                    }
                } else { action() }
                DesktopFloatingLyricsFramePersistence.isUserAdjusting = false
                dragStartMouse = nil; dragStartFrame = nil; didDrag = false
            })
        .help(label).accessibilityLabel(label)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isHovered)
    }
}

/// Clock-driven, staggered breathing dots. The timeline sleeps while paused
/// or when Reduce Motion is enabled, rather than running a hidden timer.
private struct FloatingLyricsWaitingDots: View {
    let diameter: CGFloat
    let color: Color
    let outline: Bool
    let outlineOpacity: Double
    let readabilityShadow: Double
    let animates: Bool
    let screenProgress: Double
    let screenDistance: CGFloat
    let entering: Bool
    let rightFirst: Bool
    let centerFirst: Bool
    @State private var motionAmount = 0.0
    @State private var clockRunning = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !clockRunning)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: diameter * 0.65) {
                ForEach(0..<3) { index in
                    let phase = time * 2 * .pi / 2.8 - Double(index) * 0.7
                    let wave = sin(phase) * motionAmount
                    Circle()
                        .fill(color)
                        .overlay { Circle().strokeBorder(outline ? Color.black.opacity(outlineOpacity) : .clear, lineWidth: 0.7) }
                        .shadow(color: .black.opacity(readabilityShadow), radius: 2, y: 0.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(1 + 0.10 * wave)
                        .offset(y: -2.5 * wave)
                        .modifier(WaitingDotTravel(progress: screenProgress, distance: screenDistance,
                                                   index: index, rightFirst: rightFirst, centerFirst: centerFirst, entering: entering))
                }
            }
            .frame(height: diameter + 8)
            .background { DesktopFloatingLyricsInkHitRegion() }
        }
        .task(id: animates) {
            if animates { clockRunning = true }
            withAnimation(.easeInOut(duration: 0.7)) { motionAmount = animates ? 1 : 0 }
            if !animates {
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { return }
                clockRunning = false
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("纯音乐或等待歌词")
        .accessibilityIdentifier("floatingLyrics.waitingDots")
    }
}

private struct WaitingDotTravel: ViewModifier, Animatable {
    var progress: Double
    let distance: CGFloat
    let index: Int
    let rightFirst: Bool
    let centerFirst: Bool
    let entering: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let position = CharacterScreenTransition.travelProgress(progress, index: index, total: 3, rightFirst: rightFirst, centerFirst: centerFirst, entering: entering)
        content.offset(y: distance * (1 - position))
    }
}

/// Transform glyph slices without splitting Text, preserving shaping and wrapping.
private struct LyricChangeFade: TextAttribute {
    let start: TimeInterval
    let fades: Bool
}

enum LyricSharedText {
    static func match(_ old: [String], _ new: [String]) -> Set<Int> {
        guard !old.isEmpty, !new.isEmpty, old.count <= 300, new.count <= 300 else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i][j] = old[i] == new[j] ? 1 + lengths[i + 1][j + 1] : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var i = 0, j = 0, result = Set<Int>()
        while i < old.count && j < new.count {
            if old[i] == new[j] { result.insert(j); i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        let meaningful = result.reduce(0) { $0 + new[$1].trimmingCharacters(in: .whitespacesAndNewlines).count }
        return meaningful >= 2 ? result : []
    }
}

struct LyricCharacterTiming: TextAttribute {
    let start: TimeInterval
    let end: TimeInterval
    var phaseIndex: Int = 0
    func progress(at time: TimeInterval) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        // Use the full authored singing duration, including sustained notes.
        let fadeDuration = end - start
        let fraction = min(1, max(0, (time - start) / fadeDuration))
        return fraction * fraction * (3 - 2 * fraction)
    }

    // Longer held notes leave a longer, bounded glow tail.
    private var glowReleaseDuration: TimeInterval {
        0.25 + min(0.95, max(0, end - start - 0.4) * 0.2)
    }

    // Raise the highlight smoothly as an actively sung note is held.
    func sustainedBrightness(at time: TimeInterval) -> Double {
        guard end > start, time >= start, time < end + glowReleaseDuration else { return 0 }
        let elapsed = max(0, min(time, end) - start - 0.25)
        let release = min(1, max(0, (time - end) / glowReleaseDuration))
        return 0.45 * (1 - exp(-elapsed / 1.5)) * (1 - release * release * (3 - 2 * release))
    }

    func completedDimming(at time: TimeInterval) -> Double {
        guard end > start else { return 0 }
        let fraction = min(1, max(0, (time - end - 0.5) / 0.8))
        return fraction * fraction * (3 - 2 * fraction)
    }

    // Retain the strongest dimming reached in this lyric until the line changes.
    func retainedDimmingStrength(at time: TimeInterval) -> Double {
        guard end > start, time >= start else { return 0 }
        let durationWeight = min(1, max(0, (end - start - 0.4) / 3.6))
        return (0.10 + 0.90 * durationWeight) * progress(at: min(time, end))
    }

    func glowStrength(at time: TimeInterval) -> Double {
        guard end > start, time >= start, time < end + glowReleaseDuration else { return 0 }
        // Cap the duration contribution at four seconds, keeping long notes legible.
        let durationWeight = min(1, max(0, (end - start - 0.4) / 3.6))
        let peak = 0.10 + 0.90 * durationWeight
        let release = min(1, max(0, (time - end) / glowReleaseDuration))
        let fadeOut = 1 - release * release * (3 - 2 * release)
        return peak * progress(at: min(time, end)) * fadeOut
    }
}

private struct FloatingCharacterRenderer: TextRenderer {
    let time: TimeInterval
    var amplitude: CGFloat
    var motionTime: TimeInterval? = nil
    var screenProgress: Double = 1
    var screenOffset: CGSize = .zero
    var screenAnimating = false
    var entering = true
    var rightFirst = false
    var centerFirst = false
    var glowColor: Color = .white
    var glowRadius: CGFloat = 8
    var glowIntensity: Double = 1
    var dimCompletedLyrics = true
    var outlineWidth: CGFloat = 0
    var outlineOpacity: Double = 0.08
    var readabilityShadow: Double = 0
    var projectionColor: Color = .black
    var projectionOpacity: Double = 0
    var projectionOnly = false
    var glowOnly = false
    var drawsGlow = true
    var focus: Double = 1

    var animatableData: AnimatablePair<AnimatablePair<Double, CGFloat>, Double> {
        get { AnimatablePair(AnimatablePair(focus, amplitude), screenProgress) }
        set { focus = newValue.first.first; amplitude = newValue.first.second; screenProgress = newValue.second }
    }

    var displayPadding: EdgeInsets {
        // Keep the travel drawing area unchanged when the animation starts or
        // ends, so the text doesn't jump as the view is reconfigured.
        EdgeInsets()
    }

    private enum Pass { case text, outline, halo, core, brightness }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let runTimings = layout.flatMap { line in line.map { $0[LyricCharacterTiming.self] } }
        let timings = runTimings.compactMap { $0 }
        let strengths = runTimings.map { timing in
            dimCompletedLyrics ? (timing.map { FloatingLyricsTone.dimmingStrength(for: $0, among: timings, at: time) } ?? 0) : 0
        }
        let totalGlyphs = layout.reduce(0) { total, line in total + line.reduce(0) { $0 + $1.count } }
        if projectionOnly {
            if projectionOpacity > 0 {
                var projection = context
                projection.addFilter(.shadow(color: projectionColor.opacity(projectionOpacity), radius: 2.5, y: 1.5, options: .shadowOnly))
                projection.drawLayer { layer in
                    drawRuns(layout: layout, in: &layer, pass: .text, strengths: strengths, totalGlyphs: totalGlyphs)
                }
            }
            return
        }
        if !glowOnly && readabilityShadow > 0 {
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(readabilityShadow), radius: 2, y: 0.5, options: .shadowOnly))
            shadow.drawLayer { layer in
                drawRuns(layout: layout, in: &layer, pass: .text, strengths: strengths, totalGlyphs: totalGlyphs)
            }
        }
        if !glowOnly && outlineWidth > 0 {
            var outline = context
            outline.opacity *= outlineOpacity
            outline.drawLayer { group in
                for (x, y) in [(-1.0, -1.0), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                    var edge = group
                    edge.addFilter(.shadow(color: .black, radius: 0, x: CGFloat(x) * outlineWidth, y: CGFloat(y) * outlineWidth, options: .shadowOnly))
                    edge.drawLayer { layer in
                        drawRuns(layout: layout, in: &layer, pass: .outline, strengths: strengths, totalGlyphs: totalGlyphs)
                    }
                }
            }
        }
        if drawsGlow && glowIntensity > 0 {
            // Composite the whole row's varying-alpha mask before applying blur.
            // Two filters per row replace two filters per Chinese character.
            var halo = context
            halo.addFilter(.shadow(color: glowColor, radius: glowRadius, options: .shadowOnly))
            halo.drawLayer { layer in
                drawRuns(layout: layout, in: &layer, pass: .halo, strengths: strengths, totalGlyphs: totalGlyphs)
            }
            var core = context
            core.addFilter(.shadow(color: glowColor, radius: glowRadius * 0.28, options: .shadowOnly))
            core.drawLayer { layer in
                drawRuns(layout: layout, in: &layer, pass: .core, strengths: strengths, totalGlyphs: totalGlyphs)
            }
            // Additional light is introduced only in the upper half of the
            // slider, preserving the original subtle range at lower settings.
            let gain = FloatingLyricsTone.bloomGain(intensity: glowIntensity)
            if gain > 0 {
                var bloom = context
                bloom.blendMode = .plusLighter
                bloom.addFilter(.shadow(color: glowColor.opacity(gain), radius: glowRadius * 1.25, options: .shadowOnly))
                bloom.drawLayer { layer in
                    drawRuns(layout: layout, in: &layer, pass: .halo, strengths: strengths, totalGlyphs: totalGlyphs)
                }
                var brightCore = context
                brightCore.blendMode = .plusLighter
                brightCore.addFilter(.shadow(color: Color.white.opacity(gain * 0.8), radius: max(1, glowRadius * 0.18), options: .shadowOnly))
                brightCore.drawLayer { layer in
                    drawRuns(layout: layout, in: &layer, pass: .core, strengths: strengths, totalGlyphs: totalGlyphs)
                }
            }
        }
        if !glowOnly {
            drawRuns(layout: layout, in: &context, pass: .text, strengths: strengths, totalGlyphs: totalGlyphs)
        }
        if !glowOnly && focus > 0.005 {
            var highlight = context
            highlight.blendMode = .screen
            highlight.addFilter(.shadow(color: .white, radius: 0, options: .shadowOnly))
            highlight.drawLayer { layer in
                drawRuns(layout: layout, in: &layer, pass: .brightness, strengths: strengths, totalGlyphs: totalGlyphs)
            }
        }
    }

    private func drawRuns(layout: Text.Layout, in context: inout GraphicsContext, pass: Pass, strengths: [Double], totalGlyphs: Int) {
        var index = 0
        var runIndex = 0
        for line in layout {
            for run in line {
                let timing = run[LyricCharacterTiming.self]
                var runContext = context
                if let change = run[LyricChangeFade.self], change.fades {
                    runContext.opacity *= min(1, max(0, (time - change.start) / 0.2))
                }
                let phase = (motionTime ?? time) * 2 * Double.pi / 7.2 - Double(timing?.phaseIndex ?? index) * 0.55
                runContext.translateBy(x: 0, y: amplitude * sin(phase))
                let sung = timing?.progress(at: time) ?? 1
                let brightness = FloatingLyricsTone.unplayedOpacity + (1 - FloatingLyricsTone.unplayedOpacity) * sung
                runContext.opacity *= FloatingLyricsTone.unplayedOpacity * (1 - focus) + brightness * focus
                let sustained = timing?.glowStrength(at: time) ?? 0
                let currentStrength = strengths[runIndex]
                runIndex += 1
                if (pass == .text || pass == .outline) && currentStrength > 0 {
                    runContext.opacity *= FloatingLyricsTone.completedOpacityMultiplier(currentStrength: currentStrength)
                }
                if pass == .brightness {
                    let amount = (timing?.sustainedBrightness(at: time) ?? 0) * focus
                    if amount <= 0.001 { index += run.count; continue }
                    runContext.opacity *= amount
                }
                if pass == .halo || pass == .core {
                    var alpha = FloatingLyricsTone.glowOpacity(sung: sung, sustained: sustained,
                        intensity: glowIntensity, focus: max(0.35, focus), core: pass == .core)
                    if currentStrength > 0 {
                        alpha *= FloatingLyricsTone.completedGlowMultiplier(currentStrength: currentStrength)
                    }
                    if alpha <= 0.005 { index += run.count; continue }
                    runContext.opacity *= alpha
                }
                // Use identical glyph rendering at both ends of the animation.
                for slice in run {
                    var glyph = runContext
                    if screenAnimating {
                        let eased = CharacterScreenTransition.travelProgress(screenProgress, index: index, total: totalGlyphs, rightFirst: rightFirst, centerFirst: centerFirst, entering: entering)
                        glyph.translateBy(x: screenOffset.width * (1 - eased), y: screenOffset.height * (1 - eased))
                    }
                    glyph.draw(slice, options: .disablesSubpixelQuantization)
                    index += 1
                }
            }
        }
    }
}

// The system composites the desktop behind the window; the alpha mask fades
// the material out around the lyric rather than introducing a rectangular panel.
private struct LyricSystemBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> LyricBlurView {
        let view = LyricBlurView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: LyricBlurView, context: Context) { }
}

private final class LyricBlurView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        maskImage = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                    colors: [NSColor.white.withAlphaComponent(0.21).cgColor,
                             NSColor.white.withAlphaComponent(0.185).cgColor,
                             NSColor.white.withAlphaComponent(0.12).cgColor,
                             NSColor.white.withAlphaComponent(0.045).cgColor,
                             NSColor.white.withAlphaComponent(0.0075).cgColor,
                             NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 0.25, 0.5, 0.75, 0.9, 1]) else { return false }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: rect.width / 2, y: rect.height / 2)
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
            return true
        }
    }
}
