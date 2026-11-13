import AppKit
import SwiftUI
import Foundation
import Observation

enum L10n {
    private static let bundle = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .main

    static func string(_ key: String) -> String {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }
}

@MainActor @Observable final class LyricsState {
    var lyrics = [LyricLine]() {
        didSet { hasTranslations = lyrics.contains(where: \.hasTranslation) }
    }
    private(set) var hasTranslations = false
    var isPureMusic = false
    var hasNoLyrics = false
    var sourceStatus = ""
    var sourceSongID = ""
    var selectionReason = ""
    var manualMatchSummary = ""
    var heldLine: LyricLine?
    var heldTime: TimeInterval = 0
}

struct PlaybackIndicatorFilter {
    private(set) var displayed = false
    private var switchDeadline = -Double.infinity
    private var pausedSince: TimeInterval?
    private var lastObserved: Bool?
    static let settleTime: TimeInterval = 0.65

    mutating func noteTrackSwitch(at now: TimeInterval) { switchDeadline = now + 1.8 }
    mutating func notePlaybackCommand() { switchDeadline = -.infinity; pausedSince = nil }

    // Only defer a pause during a track switch; a sustained pause is still shown.
    mutating func update(playing: Bool, at now: TimeInterval) -> Bool {
        if now < switchDeadline, let lastObserved, lastObserved != playing {
            switchDeadline = now + 1.8
        }
        lastObserved = playing
        if playing {
            displayed = true
            pausedSince = nil
        } else if displayed && now < switchDeadline {
            if pausedSince == nil { pausedSince = now }
            if now - (pausedSince ?? now) >= Self.settleTime {
                displayed = false
                pausedSince = nil
            }
        } else {
            displayed = false
            pausedSince = nil
        }
        return pausedSince != nil
    }
}

@MainActor @Observable final class SettingsState {
    let floatingLyrics = FloatingLyricsPreferences()
}

@MainActor @Observable final class DesktopAppModel {
    let player = ExternalPlayer()
    let lyrics = LyricsState()
    let settings = SettingsState()
    var status = "请在网易云音乐、QQ 音乐或 Apple Music中播放一首歌"
    var connected = false
    var artworkColor: Color?
    private(set) var playbackControlIsPlaying = false
    private(set) var trackTransitionDirection = 1
    private var pendingTrackDirection = 1
    private var lastTrackCommandTime = -Double.infinity
    private let bridge = PlaybackBridge()
    private let service = LyricsService()
    private var lyricTask: Task<Void, Never>?
    private var clock: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var started = false
    private var pendingEmpty: DispatchWorkItem?
    @ObservationIgnored private var playbackIndicator = PlaybackIndicatorFilter()
    @ObservationIgnored private var pendingIndicator: DispatchWorkItem?
    @ObservationIgnored private var recentSyncSamples = [[String: Any]]()
    @ObservationIgnored private var latestRemoteSample: RemoteSnapshot?
    var playingApplicationBundleIdentifier: String? { latestRemoteSample?.bundleIdentifier }
    private var diagnosticsPath: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--diagnostics"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    func start() {
        guard !started else { return }
        started = true
        bridge.onSnapshot = { [weak self] snapshot, origin in self?.receive(snapshot, origin: origin) }
        bridge.onError = { [weak self] message in
            guard let self else { return }
            self.connected = false
            self.player.suspend()
            self.updateClock()
            self.playbackIndicator.notePlaybackCommand()
            self.updatePlaybackIndicator()
            self.status = message
            self.writeDiagnostics()
        }
        bridge.start()
        updateClock()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    private func updateClock() {
        guard started, player.isPlaying else {
            clock?.invalidate()
            clock = nil
            return
        }
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.tick() }
        }
        timer.tolerance = 0.01
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { pendingEmpty?.cancel(); pendingIndicator?.cancel(); bridge.stop(); clock?.invalidate(); clock = nil; lyricTask?.cancel() }
    func reconnect() { connected = false; clearPlayback(); status = "正在连接音乐播放器…"; bridge.start() }

    private func clearPlayback() {
        lyricTask?.cancel()
        latestRemoteSample = nil
        player.clear()
        updateClock()
        playbackIndicator.notePlaybackCommand()
        updatePlaybackIndicator()
        lyrics.lyrics = []
        lyrics.isPureMusic = false
        lyrics.hasNoLyrics = false
        lyrics.sourceStatus = ""
        lyrics.sourceSongID = ""
        lyrics.selectionReason = ""
        lyrics.manualMatchSummary = ""
        lyrics.heldLine = nil
    }

    private func receive(_ snapshot: RemoteSnapshot?, origin: PlaybackSampleOrigin) {
        connected = true
        pendingEmpty?.cancel(); pendingEmpty = nil
        guard let snapshot, SupportedPlayers.contains(snapshot.bundleIdentifier),
              let title = snapshot.title, !title.isEmpty else {
            // Stream startup and media-service refreshes briefly emit an empty payload.
            // Keep the last line until the absence of media has settled.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.clearPlayback()
                self.status = "请在网易云音乐、QQ 音乐或 Apple Music中播放一首歌"
                self.writeDiagnostics()
            }
            pendingEmpty = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        let previousSong = player.currentSong
        let previous = previousSong?.id
        let oldTime = lyrics.heldLine == nil ? player.estimatedProgress() : lyrics.heldTime
        let oldID = LyricPlaybackTimeline.position(at: oldTime, in: lyrics.lyrics).highlightedLyricID
        let oldLine = lyrics.lyrics.first { $0.id == oldID } ?? lyrics.heldLine
        latestRemoteSample = snapshot
        player.accept(snapshot, origin: origin)
        updateClock()
        if let previousSong, previousSong.name != player.currentSong?.name || previousSong.artist != player.currentSong?.artist {
            playbackIndicator.noteTrackSwitch(at: ProcessInfo.processInfo.systemUptime)
        }
        updatePlaybackIndicator()
        FloatingLyricsWindowController.shared.playbackChanged(player.isPlaying)
        if previous != player.currentSong?.id {
            if previousSong?.name != player.currentSong?.name || previousSong?.artist != player.currentSong?.artist {
                trackTransitionDirection = ProcessInfo.processInfo.systemUptime - lastTrackCommandTime < 8 ? pendingTrackDirection : 1
                lastTrackCommandTime = -Double.infinity
            }
            let changedTrack = previousSong != nil && (previousSong?.name != player.currentSong?.name || previousSong?.artist != player.currentSong?.artist)
            reloadLyrics(holding: changedTrack ? oldLine : nil, heldTime: oldTime)
        }
        else if !lyrics.lyrics.isEmpty || lyrics.isPureMusic {
            status = lyrics.sourceStatus.isEmpty ? (lyrics.isPureMusic ? "纯音乐" : "歌词已同步") : lyrics.sourceStatus
        }
        writeDiagnostics()
    }

    func sendPlaybackCommand(_ command: Int) {
        guard [2, 4, 5].contains(command), let resources = Bundle.main.resourceURL else { return }
        if command == 4 || command == 5 {
            pendingTrackDirection = command == 5 ? -1 : 1
            lastTrackCommandTime = ProcessInfo.processInfo.systemUptime
            playbackIndicator.noteTrackSwitch(at: lastTrackCommandTime)
        } else {
            playbackIndicator.notePlaybackCommand()
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [resources.appendingPathComponent("mediaremote-adapter.pl").path,
                          resources.appendingPathComponent("MediaRemoteAdapter.framework").path, "send", String(command)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private func updatePlaybackIndicator() {
        let needsCheck = playbackIndicator.update(playing: player.isPlaying, at: ProcessInfo.processInfo.systemUptime)
        if playbackControlIsPlaying != playbackIndicator.displayed {
            playbackControlIsPlaying = playbackIndicator.displayed
        }
        if !needsCheck {
            pendingIndicator?.cancel()
            pendingIndicator = nil
        } else if pendingIndicator == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingIndicator = nil
                self.updatePlaybackIndicator()
            }
            pendingIndicator = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PlaybackIndicatorFilter.settleTime, execute: work)
        }
    }

    func seekPlayback(to seconds: Double) {
        guard seconds.isFinite, let song = player.currentSong, song.duration.isFinite, song.duration > 0,
              let resources = Bundle.main.resourceURL else { return }
        let position = min(song.duration, Double(Int64.max) / 1_000_000 - 1, max(0, seconds))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [resources.appendingPathComponent("mediaremote-adapter.pl").path,
                          resources.appendingPathComponent("MediaRemoteAdapter.framework").path,
                          "seek", String(Int64((position * 1_000_000).rounded()))]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    func reloadLyrics(refresh: Bool = false, holding: LyricLine? = nil, heldTime: TimeInterval = 0) {
        lyricTask?.cancel()
        guard let song = player.currentSong else { return }
        lyrics.lyrics = []
        lyrics.isPureMusic = false
        lyrics.hasNoLyrics = false
        lyrics.sourceStatus = ""
        lyrics.sourceSongID = ""
        lyrics.selectionReason = ""
        lyrics.heldLine = holding
        lyrics.heldTime = heldTime
        if holding != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                guard let self, self.player.currentSong?.id == song.id, self.lyrics.heldLine?.id == holding?.id else { return }
                self.lyrics.heldLine = nil
            }
        }
        status = "正在加载《\(song.name)》的歌词…"
        lyricTask = Task { [weak self, service] in
            let manual = await service.manualMatch(for: song)
            if let self, self.player.currentSong?.id == song.id {
                self.lyrics.manualMatchSummary = manual.map { "手动匹配 · \($0.name)" } ?? ""
            }
            do {
                let result = try await service.load(song, refresh: refresh) { [weak self] initial in
                    guard !Task.isCancelled, let self, self.player.currentSong?.id == song.id else { return }
                    self.lyrics.lyrics = LyricsQuality.displayLines(initial.lines)
                    self.lyrics.heldLine = nil
                    FloatingLyricsWindowController.shared.firstLyricsAvailable()
                    self.lyrics.isPureMusic = initial.pureMusic
                    self.lyrics.hasNoLyrics = initial.lines.isEmpty && !initial.pureMusic
                    self.lyrics.sourceSongID = initial.songID
                    self.lyrics.sourceStatus = initial.displayStatus
                    self.lyrics.selectionReason = "正在比较 QQ 音乐歌词…"
                    self.status = initial.displayStatus
                }
                try Task.checkCancellation()
                guard let self, self.player.currentSong?.id == song.id else { return }
                self.lyrics.lyrics = LyricsQuality.displayLines(result.lines)
                self.lyrics.heldLine = nil
                FloatingLyricsWindowController.shared.firstLyricsAvailable()
                self.lyrics.isPureMusic = result.pureMusic
                self.lyrics.hasNoLyrics = result.lines.isEmpty && !result.pureMusic
                self.lyrics.sourceSongID = result.songID
                self.lyrics.sourceStatus = result.displayStatus
                self.lyrics.selectionReason = result.selectionReason
                self.status = result.displayStatus
                self.writeDiagnostics()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, let self, self.player.currentSong?.id == song.id else { return }
                self.lyrics.heldLine = nil
                if case LyricsFailure.noLyrics = error { self.lyrics.hasNoLyrics = true }
                self.status = error.localizedDescription
                self.writeDiagnostics()
            }
        }
    }

    func searchLyrics(query: String) async throws -> [TrackCandidate] {
        try await service.search(query)
    }

    func applyLyricsMatch(_ candidate: TrackCandidate) {
        guard let song = player.currentSong else { return }
        lyricTask?.cancel()
        lyricTask = Task { [weak self, service] in
            await service.remember(candidate, for: song)
            guard let self, self.player.currentSong?.id == song.id else { return }
            self.lyrics.manualMatchSummary = "手动匹配 · \(candidate.name)"
            self.reloadLyrics(refresh: true)
        }
    }

    func clearLyricsMatch() {
        guard let song = player.currentSong else { return }
        lyricTask?.cancel()
        lyricTask = Task { [weak self, service] in
            await service.forgetMatch(for: song)
            guard let self, self.player.currentSong?.id == song.id else { return }
            self.lyrics.manualMatchSummary = ""
            self.reloadLyrics(refresh: true)
        }
    }

    func recordSyncIssue() {
        let now = Date()
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Flowflow", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = folder.appendingPathComponent("错位现场-\(formatter.string(from: now)).json")
        let report: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "markedAt": ISO8601DateFormatter().string(from: now),
            "current": syncDiagnosticSample(), "recentSamples": recentSyncSamples,
            "lyricTimeline": lyrics.lyrics.map { ["time": $0.time, "text": $0.text] as [String: Any] }
        ]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            let alert = NSAlert()
            alert.messageText = "已记录此刻的同步问题"
            alert.informativeText = "已保存最近的播放样本、计算进度和歌词来源。不会重新连接或改变播放。\n\n记录位置：\(url.path)"
            alert.addButton(withTitle: "好")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能保存同步记录"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func syncDiagnosticSample() -> [String: Any] {
        let line = LyricPlaybackTimeline.position(at: player.estimatedProgress(), in: lyrics.lyrics).highlightedLyricID
        var json: [String: Any] = ["title": player.currentSong?.name ?? "", "artist": player.currentSong?.artist ?? "",
            "playing": player.isPlaying, "progress": player.estimatedProgress(), "status": status,
            "lastSyncOrigin": player.lastSampleOrigin.rawValue, "lastSyncCorrection": player.lastCorrection,
            "discardedTimingSamples": player.discardedTimingSamples,
            "lyricsSource": lyrics.sourceStatus, "selectionReason": lyrics.selectionReason,
            "lyricCount": lyrics.lyrics.count, "currentLine": line ?? "", "connected": connected]
        json["capturedAt"] = ISO8601DateFormatter().string(from: Date())
        json["uptime"] = ProcessInfo.processInfo.systemUptime
        json["manualOffset"] = player.offset
        json["sourceSongID"] = lyrics.sourceSongID
        if let sample = latestRemoteSample, let data = try? JSONEncoder().encode(sample),
           let raw = try? JSONSerialization.jsonObject(with: data) { json["remoteSample"] = raw }
        return json
    }

    private func writeDiagnostics() {
        let json = syncDiagnosticSample()
        recentSyncSamples.append(json)
        if recentSyncSamples.count > 180 { recentSyncSamples.removeFirst(recentSyncSamples.count - 180) }
        guard let path = diagnosticsPath else { return }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

@MainActor enum PreferencesMigration {
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "standalone.preferencesImported") else { return }
        if defaults.object(forKey: "floatingLyrics.textEffect") == nil {
            defaults.set("glow", forKey: "floatingLyrics.textEffect")
        }
        defaults.set(true, forKey: "standalone.preferencesImported")
    }
}
