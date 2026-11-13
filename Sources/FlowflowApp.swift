import SwiftUI
import AppKit

@main struct FlowflowApp: App {
    @NSApplicationDelegateAdaptor(FlowflowDelegate.self) private var appDelegate
    @State private var model: DesktopAppModel
    init() {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--artwork-color-test"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let image = NSImage(contentsOfFile: ProcessInfo.processInfo.arguments[index + 1]),
           let rgb = ArtworkLyricColor.dominantColor(image) {
            print(String(format: "#%02X%02X%02X", Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded())))
            exit(0)
        }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--qq-source-test") {
            let args = ProcessInfo.processInfo.arguments
            SelfTests.runQQSource(fixture: args.indices.contains(index + 1) ? args[index + 1] : nil)
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("--sync-recovery-test") {
            SelfTests.runSyncRecovery()
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("--recovery-test") {
            SelfTests.runRecovery()
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("--integration-test") {
            SelfTests.runLive()
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            SelfTests.run()
            exit(0)
        }
        PreferencesMigration.run()
        let model = DesktopAppModel()
        _model = State(initialValue: model)
        model.start()
        FloatingLyricsWindowController.shared.model = model
    }

    var body: some Scene {
        Window("Flowflow 设置", id: "settings") {
            PreferencesView(model: model)
                .frame(width: 470, height: 610)
        }
        .defaultSize(width: 470, height: 610)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("搜索歌词", id: "lyrics-search") {
            LyricsSearchView(model: model)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 520)
        }
        .defaultSize(width: 520, height: 520)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra("Flowflow", systemImage: "text.bubble.fill") {
            TrayMenu(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct TrayHoverHighlight: ViewModifier {
    var isPressed = false
    var bordered = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let highlighted = isHovered && isEnabled
        let fillOpacity: Double = !isEnabled ? 0 : isPressed ? 0.22
            : highlighted ? (colorScheme == .dark ? 0.15 : 0.09) : bordered ? 0.07 : 0
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(highlighted ? 0.42 : 0), lineWidth: 1)
                    }
                    .shadow(color: Color.accentColor.opacity(highlighted ? 0.20 : 0), radius: 6)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: highlighted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: isPressed)
    }
}

private struct TrayHoverButtonStyle: ButtonStyle {
    var bordered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(TrayHoverHighlight(isPressed: configuration.isPressed, bordered: bordered))
    }
}

private struct ArtworkPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.58), value: configuration.isPressed)
    }
}

private struct SyncOffsetControls: View {
    @Bindable var player: ExternalPlayer
    var body: some View {
        HStack(spacing: 12) {
            Button { player.adjustOffset(by: -0.1) } label: {
                Image(systemName: "minus").frame(width: 24, height: 22)
            }
            .accessibilityLabel("歌词延后 0.1 秒")
            .help("歌词延后 0.1 秒")
            VStack(spacing: 2) {
                Text("歌词时间").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%+.1f 秒", player.offset == 0 ? 0 : player.offset))
                    .font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Button { player.adjustOffset(by: 0.1) } label: {
                Image(systemName: "plus").frame(width: 24, height: 22)
            }
            .accessibilityLabel("歌词提前 0.1 秒")
            .help("歌词提前 0.1 秒")

        }
        .buttonStyle(TrayHoverButtonStyle(bordered: true))
        .controlSize(.regular)
    }
}

private struct PlaybackSummary: View {
    @Bindable var model: DesktopAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.player.currentSong?.name ?? "等待播放")
                .font(.headline).lineLimit(2).textSelection(.enabled)
            if let song = model.player.currentSong {
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("\(clockText(model.player.progress)) / \(clockText(song.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.top, 3)
                if !model.lyrics.manualMatchSummary.isEmpty {
                    Text(model.lyrics.manualMatchSummary)
                        .font(.caption2).foregroundStyle(.tint).lineLimit(1)
                } else if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("在网易云音乐、QQ 音乐或 Apple Music中播放一首歌").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clockText(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TrayPlaybackButton: View {
    let symbol: String
    let label: String
    let glowColor: Color
    let action: () -> Void
    @State private var hovered = false
    @AppStorage("floatingLyrics.projectionStrength") private var projectionStrength = 0.45
    @AppStorage("floatingLyrics.readabilityStrength") private var readabilityStrength = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: playbackControlSymbolWeight(symbol)))
                .foregroundStyle(Color.primary)
                .shadow(color: .black.opacity(min(1, max(0, projectionStrength)) * 0.45), radius: 2.5, y: 1.5)
                .shadow(color: .black.opacity(max(0, min(1, readabilityStrength) - 0.5) * 0.6), radius: 2, y: 0.5)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(glowColor.opacity(hovered ? 0.8 : 0))
                        .frame(width: 36, height: 36).blur(radius: 13)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: hovered)
        .help(label).accessibilityLabel(label)
    }
}

private struct TrayProgressBar: View {
    @Bindable var model: DesktopAppModel
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverX: CGFloat = 0
    @State private var preview: Double?
    @State private var dragSongID: String?
    @State private var dragStretch: CGFloat = 0
    @State private var dragVertical: CGFloat = 0
    @State private var seekToken = UUID()

    private var duration: Double {
        let value = model.player.currentSong?.duration ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    var body: some View {
        let _ = model.player.progress
        let fraction = duration > 0 ? min(1, max(0, (preview ?? model.player.playbackPosition()) / duration)) : 0
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let thickness: CGFloat = hovered || dragSongID != nil ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.20))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: width * fraction)
                    .overlay(alignment: .trailing) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.player.isPlaying || reduceMotion)) { context in
                            let pulse = model.player.isPlaying && !reduceMotion
                                ? 0.90 + 0.10 * (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 3.2) + 1) / 2 : 0.95
                            LinearGradient(colors: [.clear, color.opacity(0.45 * pulse), .white.opacity(0.60 * pulse)],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                        .frame(width: min(30, width * fraction))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .clipShape(Capsule())
                    .shadow(color: color.opacity(0.65), radius: hovered ? 7 : 4)
                Capsule().fill(RadialGradient(
                    colors: [.white.opacity(0.55), color.opacity(0.55), .clear],
                    center: UnitPoint(x: width > 0 ? min(1, max(0, hoverX / width)) : 0, y: 0.5),
                    startRadius: 0, endRadius: 14))
                    .mask(alignment: .leading) {
                        Capsule().frame(width: width * fraction)
                    }
                    .blendMode(.plusLighter)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(height: thickness)
            .animation(reduceMotion || preview != nil ? nil : .linear(duration: 0.12), value: fraction)
            .scaleEffect(x: hovered || dragSongID != nil ? 1.035 : 1, y: 1, anchor: .center)
            .scaleEffect(x: 1 + abs(dragStretch), y: 1, anchor: dragStretch < 0 ? .trailing : .leading)
            .scaleEffect(x: 1, y: 1 + abs(dragVertical) / 3 * 0.06, anchor: dragVertical < 0 ? .bottom : .top)
            .offset(y: dragVertical)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.68), value: dragStretch)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.68), value: dragVertical)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard duration > 0, width > 0 else { return }
                hoverX = event.location.x
                if dragSongID == nil {
                    seekToken = UUID()
                    dragSongID = model.player.currentSong?.id
                }
                guard dragSongID == model.player.currentSong?.id else { preview = nil; return }
                dragStretch = min(0.035, max(-0.035, event.translation.width / 1800))
                dragVertical = min(3, max(-3, event.translation.height * 0.10))
                preview = duration * min(1, max(0, event.location.x / width))
            }.onEnded { event in
                if let preview, dragSongID == model.player.currentSong?.id {
                    model.seekPlayback(to: preview)
                    let token = UUID(); seekToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if seekToken == token { self.preview = nil }
                    }
                } else { preview = nil }
                dragSongID = nil
                dragStretch = 0
                dragVertical = 0
                hovered = CGRect(origin: .zero, size: geometry.size).contains(event.location)
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x; hovered = true
                case .ended: hovered = false
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.68), value: hovered)
        }
        .frame(height: 22)
        .opacity(duration > 0 ? 1 : 0.35)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int(fraction * 100))%")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            let delta = direction == .increment ? 5.0 : -5.0
            model.seekPlayback(to: model.player.playbackPosition() + delta)
        }
        .onChange(of: model.player.currentSong?.id) { _, _ in preview = nil; dragSongID = nil; dragStretch = 0; dragVertical = 0; seekToken = UUID() }
    }
}

private struct SongInfoSnapshot: Equatable {
    let title: String
    let artist: String?
    let album: String?

    init(_ song: Song?) {
        title = song?.name ?? "等待播放"
        artist = song?.artist
        album = song?.albumName
    }
}

enum SongInfoMotion {
    static let distance: CGFloat = 12
    static let duration = 0.46

    static func offset(direction: Int, incoming: Bool, progress: CGFloat) -> CGFloat {
        let sign: CGFloat = direction < 0 ? -1 : 1
        return sign * distance * (incoming ? 1 - progress : -progress)
    }
}

private struct SongInfoTransition: View {
    let song: SongInfoSnapshot
    let direction: Int
    let reduceMotion: Bool
    @State private var displayed: SongInfoSnapshot?
    @State private var outgoing: SongInfoSnapshot?
    @State private var progress: CGFloat = 1
    @State private var transitionDirection = 1
    @State private var transitionID = UUID()

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoing {
                songText(outgoing)
                    .offset(y: SongInfoMotion.offset(direction: transitionDirection, incoming: false, progress: progress))
                    .opacity(1 - progress)
                    .accessibilityHidden(true)
            }
            songText(displayed ?? song)
                .offset(y: outgoing == nil ? 0 : SongInfoMotion.offset(direction: transitionDirection, incoming: true, progress: progress))
                .opacity(outgoing == nil ? 1 : progress)
        }
        .onChange(of: song, initial: true) { _, next in
            guard let previous = displayed, previous != next, !reduceMotion else {
                transitionID = UUID()
                displayed = next
                outgoing = nil
                progress = 1
                return
            }
            let id = UUID()
            transitionID = id
            transitionDirection = direction
            outgoing = previous
            displayed = next
            progress = 0
            DispatchQueue.main.async {
                guard transitionID == id else { return }
                withAnimation(.easeInOut(duration: SongInfoMotion.duration)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + SongInfoMotion.duration) {
                    guard transitionID == id else { return }
                    outgoing = nil
                }
            }
        }
    }

    private func songText(_ info: SongInfoSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(info.title).font(.system(size: 18, weight: .bold)).lineLimit(2)
            if let artist = info.artist {
                Text(artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrayMenu: View {
    @Bindable var model: DesktopAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("floatingLyrics.fixedPosition") private var fixedPosition = false
    @AppStorage("floatingLyrics.hoverControls") private var hoverControls = true
    @AppStorage("floatingLyrics.artworkColorEnabled") private var artworkColorEnabled = true
    @AppStorage("floatingLyrics.customColorEnabled") private var customColorEnabled = false
    @AppStorage("floatingLyrics.colorRed") private var colorRed = 1.0
    @AppStorage("floatingLyrics.colorGreen") private var colorGreen = 1.0
    @AppStorage("floatingLyrics.colorBlue") private var colorBlue = 1.0
    @State private var artwork: NSImage?
    @State private var artworkData: Data?
    @State private var artworkRevision: UUID?
    @State private var artworkHover: CGPoint?
    private var artworkTiltX: Double {
        guard !reduceMotion, let point = artworkHover else { return 0 }
        return Double(min(1, max(-1, (point.y - 48) / 48))) * 8
    }
    private var artworkTiltY: Double {
        guard !reduceMotion, let point = artworkHover else { return 0 }
        return -Double(min(1, max(-1, (point.x - 48) / 48))) * 8
    }
    private var lyricColor: Color {
        if SongColorOverride.isGoldenHour(model.player.currentSong) { return Color(red: 1, green: 161.0 / 255, blue: 60.0 / 255) }
        let fallback: Color = model.settings.floatingLyrics.backgroundStyle.usesLightForeground ? .white : .primary
        if artworkColorEnabled { return model.artworkColor ?? fallback }
        return customColorEnabled ? Color(red: colorRed, green: colorGreen, blue: colorBlue) : fallback
    }
    private let controller = FloatingLyricsWindowController.shared
    var body: some View {
        @Bindable var prefs = model.settings.floatingLyrics
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    guard let id = model.playingApplicationBundleIdentifier,
                          SupportedPlayers.contains(id) else { return }
                    let player = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
                    player?.unhide()
                    guard let url = player?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                        player?.activate(options: [])
                        return
                    }
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = true
                    options.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                        if let error { NSLog("Flowflow could not open player: %@", error.localizedDescription) }
                    }
                } label: {
                    ZStack {
                        Group {
                            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                            else { Image(systemName: "music.note").font(.system(size: 32)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
                        }
                        .frame(width: 96, height: 96)
                        .id(artworkRevision)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(x: CGFloat(model.trackTransitionDirection) * 8)),
                            removal: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(x: CGFloat(model.trackTransitionDirection) * -8))))
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: artworkRevision)
                    .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
                    .rotation3DEffect(.degrees(artworkTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.65)
                    .rotation3DEffect(.degrees(artworkTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.38), value: artworkHover)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ArtworkPressStyle())
                .background {
                    GeometryReader { geometry in
                        if let point = artworkHover {
                            let angle = atan2(point.y - geometry.size.height / 2, point.x - geometry.size.width / 2) * 180 / .pi
                            let distanceX = abs(point.x - geometry.size.width / 2) / max(1, geometry.size.width / 2)
                            let distanceY = abs(point.y - geometry.size.height / 2) / max(1, geometry.size.height / 2)
                            let edgeProximity = min(1, max(distanceX, distanceY))
                            RoundedRectangle(cornerRadius: 18)
                                .fill(lyricColor.opacity(0.50))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .fill(AngularGradient(gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.55), location: 0),
                                            .init(color: lyricColor.opacity(0.55), location: 0.10),
                                            .init(color: .clear, location: 0.25),
                                            .init(color: .clear, location: 0.75),
                                            .init(color: lyricColor.opacity(0.55), location: 0.90),
                                            .init(color: .white.opacity(0.55), location: 1)
                                        ]), center: .center, angle: .degrees(angle)))
                                        .blendMode(.plusLighter)
                                        .opacity(0.15 + 0.85 * edgeProximity)
                                }
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .blur(radius: 18).transition(.opacity)
                        }
                    }.allowsHitTesting(false)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: artworkHover != nil)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): artworkHover = point
                    case .ended: artworkHover = nil
                    }
                }
                .disabled(model.player.currentSong == nil || model.playingApplicationBundleIdentifier == nil)
                .help("打开正在播放的音乐软件")
                .accessibilityLabel("打开正在播放的音乐软件")
                VStack(alignment: .leading, spacing: 7) {
                SongInfoTransition(song: SongInfoSnapshot(model.player.currentSong),
                                   direction: model.trackTransitionDirection, reduceMotion: reduceMotion)
                TrayProgressBar(model: model, color: lyricColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            DesktopFloatingLyricsWindow(menuPreview: true)
                .environment(model)
                .frame(height: 145).clipped()
            HStack(spacing: 12) {
                TrayPlaybackButton(symbol: "minus", label: "歌词延后 0.1 秒", glowColor: lyricColor) { model.player.adjustOffset(by: -0.1) }
                TrayPlaybackButton(symbol: "backward.end.fill", label: "上一首", glowColor: lyricColor) { model.sendPlaybackCommand(5) }
                TrayPlaybackButton(symbol: model.playbackControlIsPlaying ? "pause.fill" : "play.fill", label: model.playbackControlIsPlaying ? "暂停" : "播放", glowColor: lyricColor) { model.sendPlaybackCommand(2) }
                TrayPlaybackButton(symbol: "forward.end.fill", label: "下一首", glowColor: lyricColor) { model.sendPlaybackCommand(4) }
                TrayPlaybackButton(symbol: "plus", label: "歌词提前 0.1 秒", glowColor: lyricColor) { model.player.adjustOffset(by: 0.1) }
            }
            .padding(.vertical, 5)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            Divider()
            VStack(spacing: 12) {
                Toggle(isOn: Binding(get: { controller.isVisible }, set: { controller.setVisible($0) })) {
                    Text("显示悬浮歌词").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                Toggle(isOn: $prefs.showsTranslation) {
                    Text("显示翻译").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                Toggle(isOn: $prefs.showsNextLine) {
                    Text("显示下一句").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                Toggle(isOn: $hoverControls) {
                    Text("悬停控制").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                Toggle(isOn: $fixedPosition) {
                    Text("固定位置").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                    .help("开启后不能拖动歌词位置")
            }
            .toggleStyle(.switch).controlSize(.small)
            Divider()
            Button {
                openWindow(id: "lyrics-search")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("搜索歌词…", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
            .disabled(model.player.currentSong == nil)
            .help(model.player.currentSong == nil ? "先播放一首歌后再搜索匹配歌词" : "用关键词在线搜索并手动匹配歌词")
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("设置…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            Button("退出Flowflow") { NSApp.terminate(nil) }.keyboardShortcut("q")
                .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4).foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("当前版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")")
        }
        .padding(18)
        .frame(width: 360)
        .task(id: model.player.currentSong.map { SongInfoSnapshot($0) }) {
            guard let song = model.player.currentSong else {
                artwork = nil; artworkData = nil; artworkRevision = nil
                return
            }
            let requestedSong = SongInfoSnapshot(song)
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                guard !Task.isCancelled else { return }
                if let data = await ArtworkLyricColor.loadArtwork(for: song), let image = NSImage(data: data) {
                    guard !Task.isCancelled, model.player.currentSong != nil,
                          SongInfoSnapshot(model.player.currentSong) == requestedSong else { return }
                    if data != artworkData {
                        artwork = image
                        artworkData = data
                        artworkRevision = UUID()
                    }
                    if artworkColorEnabled, let rgb = ArtworkLyricColor.dominantColor(image) {
                        model.artworkColor = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
                    }
                    return
                }
            }
            if !Task.isCancelled, model.player.currentSong != nil,
               SongInfoSnapshot(model.player.currentSong) == requestedSong {
                artwork = nil; artworkData = nil; artworkRevision = nil
            }
        }
    }
}

private struct PreferencesView: View {
    @Bindable var model: DesktopAppModel
    @AppStorage("floatingLyrics.hoverControls") private var hoverControls = true
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
    @AppStorage("floatingLyrics.positionPreset") private var positionPreset = ""
    @State private var installedFonts = [String]()
    @State private var lastFontRefresh = -Double.infinity
    @State private var confirmingReset = false
    @State private var showingPositionPresets = false
    var body: some View {
        @Bindable var prefs = model.settings.floatingLyrics
        Form {
            Section("歌词位置") {
                LabeledContent("预设位置") {
                    Button {
                        showingPositionPresets.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(LyricsPositionPreset(rawValue: positionPreset)?.title ?? "自定义位置")
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }.frame(minWidth: 110)
                    }
                    .popover(isPresented: $showingPositionPresets, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(LyricsPositionPreset.allCases) { preset in
                                Button {
                                    FloatingLyricsWindowController.shared.applyPositionPreset(preset)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: positionPreset == preset.rawValue ? "checkmark" : "")
                                            .frame(width: 14)
                                        Image(nsImage: preset.icon).frame(width: 18)
                                        Text(preset.title)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(Color(nsColor: .textColor))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                        }
                        .padding(8).frame(width: 185)
                    }
                }
                LabeledContent("位置微调") {
                    HStack(spacing: 6) {
                        positionNudge("arrow.left", label: "向左移动", dx: -1, dy: 0)
                        positionNudge("arrow.up", label: "向上移动", dx: 0, dy: 1)
                        positionNudge("arrow.down", label: "向下移动", dx: 0, dy: -1)
                        positionNudge("arrow.right", label: "向右移动", dx: 1, dy: 0)
                    }
                }.help("每次移动 1 点；预设位置下的微调会随歌词变化保留。")
            }
            Section("歌词外观") {
                Toggle("跟随歌曲封面颜色", isOn: artworkColorBinding)
                Toggle("自定义歌词颜色", isOn: customColorBinding)
                if customColorEnabled && !artworkColorEnabled {
                    ColorPicker("歌词颜色", selection: lyricColor, supportsOpacity: false)
                }
                Toggle("文字细黑边", isOn: $blackOutline)
                LabeledContent("易读性强度") {
                    NumericSlider(value: $readabilityStrength, range: 0...1, step: 0.01, scale: 100, suffix: "%", label: "易读性强度")
                }
                .help("调节歌词附近的调暗和柔和阴影；开启细黑边时也会适度增强黑边。")
                LabeledContent("歌词投影") {
                    NumericSlider(value: $projectionStrength, range: 0...1, step: 0.01, scale: 100, suffix: "%", label: "歌词投影")
                }.help("调整歌词下方同色系深色投影的强度。")
                Toggle("逐字轻微漂浮", isOn: $characterFloat)
                LabeledContent("漂浮幅度") {
                    NumericSlider(value: $floatAmplitude, range: 0...6, step: 0.1, label: "漂浮幅度")
                }
                .disabled(!characterFloat)
                LabeledContent("字体") {
                    LyricsFontPicker(selection: $prefs.fontFamily, families: installedFonts)
                        .frame(width: 240, height: 24)
                }
                LabeledContent("字号") {
                    NumericSlider(value: $prefs.fontScale, range: FloatingLyricsPreferences.fontScaleRange, scale: 100, suffix: "%", label: "字号")
                }
                Picker("字重", selection: $prefs.fontWeight) {
                    ForEach(LyricsFontWeight.allCases) { Text($0.title).tag($0) }
                }
                Picker("对齐", selection: $prefs.textAlignment) {
                    ForEach(FloatingLyricsTextAlignment.allCases) { Text($0.title).tag($0) }
                }
                Picker("文字效果", selection: $prefs.textEffect) {
                    ForEach(FloatingLyricsTextEffect.allCases) { Text($0.title).tag($0) }
                }
                Toggle("唱过的歌词逐渐淡出", isOn: $prefs.dimCompletedLyrics)
                    .help("关闭后，唱过的文字和辉光保持原有透明度。")
                if prefs.textEffect == .glow {
                    LabeledContent("发光强度") { NumericSlider(value: $prefs.glowIntensity, range: FloatingLyricsPreferences.glowIntensityRange, label: "发光强度") }
                    LabeledContent("发光范围") { NumericSlider(value: $prefs.glowRadius, range: 2...30, label: "发光范围") }
                }
                LabeledContent("文字不透明度") { NumericSlider(value: $prefs.textOpacity, range: FloatingLyricsPreferences.textOpacityRange, scale: 100, suffix: "%", label: "文字不透明度") }
                LabeledContent("行间距") { NumericSlider(value: $prefs.lineSpacing, range: 2...18, label: "行间距") }
            }
            Section {
                Button("恢复默认设置") { confirmingReset = true }
                    .confirmationDialog("恢复默认设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
                        Button("恢复默认", role: .destructive) { restoreDefaults() }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("将恢复歌词外观、固定位置、悬停控制、位置和歌曲延迟默认值。之后调整过的歌曲延迟会被清除。")
                    }
            }
        }
        .formStyle(.grouped)
        .focusEffectDisabled()
        .onAppear { refreshFonts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFonts()
        }
    }

    private func positionNudge(_ symbol: String, label: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button { FloatingLyricsWindowController.shared.nudgePosition(dx: dx, dy: dy) } label: {
            Image(systemName: symbol).frame(width: 20)
        }.help(label).accessibilityLabel(label)
    }

    private func restoreDefaults() {
        model.settings.floatingLyrics.reset()
        readabilityStrength = 0.5
        projectionStrength = 0.45
        blackOutline = false
        characterFloat = true
        floatAmplitude = 6.0
        artworkColorEnabled = true
        customColorEnabled = false
        colorRed = 1.0; colorGreen = 1.0; colorBlue = 1.0
        UserDefaults.standard.set(false, forKey: "floatingLyrics.fixedPosition")
        hoverControls = true
        model.player.restoreDefaultOffsets()
        UserDefaults.standard.removeObject(forKey: DesktopFloatingLyricsFramePersistence.key)
        if let window = NSApp.windows.first(where: { $0.title == "悬浮歌词" }) {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let screen {
                var frame = window.frame
                frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
                window.setFrame(frame, display: true)
                DesktopFloatingLyricsFramePersistence.save(frame, window: window)
            }
        }
    }

    private var artworkColorBinding: Binding<Bool> {
        Binding(get: { artworkColorEnabled }, set: { enabled in
            if enabled { customColorEnabled = false }
            artworkColorEnabled = enabled
        })
    }

    private var customColorBinding: Binding<Bool> {
        Binding(get: { customColorEnabled }, set: { enabled in
            if enabled { artworkColorEnabled = false }
            customColorEnabled = enabled
        })
    }

    private var lyricColor: Binding<Color> {
        Binding(get: { Color(red: colorRed, green: colorGreen, blue: colorBlue) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            colorRed = Double(rgb.redComponent)
            colorGreen = Double(rgb.greenComponent)
            colorBlue = Double(rgb.blueComponent)
        })
    }

    private func refreshFonts() {
        // Opening the window can also activate the app. Avoid enumerating and
        // sorting the same system font list twice for that single interaction.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFontRefresh >= 0.5 else { return }
        lastFontRefresh = now
        let families = LyricsFontFamily.installedFamilies()
        if installedFonts != families { installedFonts = families }
        let selected = model.settings.floatingLyrics.fontFamily
        if !selected.isEmpty && !families.contains(selected) {
            model.settings.floatingLyrics.fontFamily = ""
        }
    }
}

private struct LyricsSearchView: View {
    @Bindable var model: DesktopAppModel
    @State private var query = ""
    @State private var results = [TrackCandidate]()
    @State private var searching = false
    @State private var applyingID: String?
    @State private var message = ""
    @State private var searched = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let song = model.player.currentSong {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前播放").font(.caption).foregroundStyle(.secondary)
                    Text(song.name).font(.headline).lineLimit(2)
                    Text([song.artist, song.albumName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if !model.lyrics.manualMatchSummary.isEmpty {
                        Text(model.lyrics.manualMatchSummary)
                            .font(.caption).foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("请先在支持的播放器中播放一首歌")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("输入中文歌名、歌手等关键词", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit { Task { await runSearch() } }
                    .disabled(model.player.currentSong == nil || searching)
                Button(searching ? "搜索中…" : "搜索") {
                    Task { await runSearch() }
                }
                .disabled(model.player.currentSong == nil || searching
                          || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            Group {
                if searching && results.isEmpty {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    Text(searched ? "没有找到相关歌曲，换个关键词试试" : "Apple Music 歌名对不上时，可在这里搜中文名并手动选择")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 8)
                } else {
                    List(results) { candidate in
                        Button {
                            apply(candidate)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.name).font(.body.weight(.medium)).lineLimit(2)
                                    Text(candidate.artistText)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if !candidate.album.isEmpty {
                                        Text(candidate.album)
                                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(candidate.durationText)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if applyingID == candidate.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("使用").font(.caption).foregroundStyle(.tint)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingID != nil)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if !model.lyrics.manualMatchSummary.isEmpty {
                    Button("清除手动匹配") {
                        model.clearLyricsMatch()
                        message = "已清除手动匹配，将重新自动匹配"
                    }
                    .disabled(applyingID != nil)
                }
                Spacer()
                Text("来源：网易云搜索")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .onAppear {
            syncQueryFromSong(force: query.isEmpty)
            queryFocused = true
            if model.player.currentSong != nil,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !searched {
                Task { await runSearch() }
            }
        }
        .onChange(of: model.player.currentSong?.id) { _, _ in
            syncQueryFromSong(force: true)
            results = []
            searched = false
            message = ""
            applyingID = nil
        }
    }

    private func syncQueryFromSong(force: Bool) {
        guard force || query.isEmpty, let song = model.player.currentSong else { return }
        query = [song.name, song.artist].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @MainActor
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.player.currentSong != nil, !trimmed.isEmpty else { return }
        searching = true
        message = ""
        defer { searching = false }
        do {
            results = try await model.searchLyrics(query: trimmed)
            searched = true
            message = results.isEmpty ? "" : "找到 \(results.count) 首，点选即可匹配到当前播放"
        } catch {
            results = []
            searched = true
            message = error.localizedDescription
        }
    }

    private func apply(_ candidate: TrackCandidate) {
        applyingID = candidate.id
        message = "正在应用《\(candidate.name)》…"
        model.applyLyricsMatch(candidate)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            applyingID = nil
            message = "已匹配《\(candidate.name)》，下次播放会自动使用"
        }
    }
}
