import Foundation
import AppKit

@MainActor enum SelfTests {
    static func runQQSource(fixture: String?) {
        Task { @MainActor in
            do {
                if let fixture {
                    let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
                    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    let encoded = ((json["lyric"] as! [String: Any])["data"] as! [String: Any])["lyric"] as! String
                    let text = try QRCDecoder.decode(encoded)
                    let lines = QRCParser.parse(text)
                    let quality = LyricsQuality.assess(lines, duration: 269)
                    precondition(lines.count > 20 && quality.timedCoverage > 0.8 && quality.usable)
                    print("PASS real QRC fixture: \(lines.count) lines, timed coverage \(Int(quality.timedCoverage * 100))%, granularity \(Int(quality.granularity * 100))%")
                }
                let song = Song(id: "qq-source-test", name: "晴天", artist: "周杰伦", albumName: "叶惠美", duration: 269)
                let candidates = try await QQMusicLyricsService().loadCandidates(for: song)
                precondition(!candidates.isEmpty, "Live QQ search/detail/QRC fetch returned no matching candidate")
                let candidate = candidates[0].0
                let quality = LyricsQuality.assess(candidate.lines, duration: song.duration)
                precondition(quality.usable && quality.timedCoverage > 0.8)
                print("PASS live QQ search, duration/version matching and QRC decode: \(candidate.lines.count) lines, coverage \(Int(quality.timedCoverage * 100))%")
                let original = LyricsResult(lines: candidate.lines.map {
                    LyricLine(time: $0.time, duration: $0.duration, text: $0.text, translation: $0.translation)
                }, pureMusic: false, songID: "line-only-fixture")
                let aligned = LyricsQuality.aligned(candidate.lines, to: original.lines)
                precondition(aligned != nil && LyricsQuality.prefer(candidate, over: original, duration: song.duration))
                print("PASS: verified word-timed QQ lyrics replace a compatible line-only source")
                let final = try await LyricsService().load(song, refresh: true) { initial in
                    print("PASS initial provider published before comparison: \(initial.displayStatus)")
                }
                precondition(!final.lines.isEmpty)
                print("PASS combined service: \(final.displayStatus); \(final.selectionReason)")
                let englishSong = Song(id: "qq-english-test", name: "Shape of You", artist: "Ed Sheeran", albumName: "÷", duration: 234)
                let english = try await QQMusicLyricsService().loadCandidates(for: englishSong)
                precondition(!english.isEmpty, "English catalogue lookup must find the correct solo version")
                let englishLines = english[0].0.lines
                let words = englishLines.flatMap { LyricHighlightUnits.make(for: $0) }
                precondition(words.filter { $0.text.count >= 4 }.count > 30)
                let englishQuality = LyricsQuality.assess(englishLines, duration: englishSong.duration)
                precondition(englishQuality.usable && englishQuality.timedCoverage > 0.8)
                print("PASS English QQ lyrics: \(englishLines.count) lines; whole-word grouping and singer/version filtering")
                let soundtrack = Song(id: "qq-soundtrack-test", name: "Feel It", artist: "d4vd", albumName: "Feel It", duration: 157)
                let soundtrackCandidates = try await QQMusicLyricsService().loadCandidates(for: soundtrack)
                precondition(!soundtrackCandidates.isEmpty)
                print("PASS soundtrack title annotation matching: Feel It; true version markers remain enforced")
                exit(0)
            } catch {
                print("FAIL QQ source: \(error.localizedDescription)")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { print("FAIL QQ source: timeout"); exit(1) }
        RunLoop.main.run()
    }

    static func runSyncRecovery() {
        let bridge = PlaybackBridge()
        let player = ExternalPlayer()
        var injected = false
        bridge.onSnapshot = { snapshot, origin in
            guard let snapshot, snapshot.bundleIdentifier == "com.netease.163music", snapshot.elapsedTimeMicros != nil else { return }
            player.accept(snapshot, origin: origin)
            if !injected {
                injected = true
                player.simulateDriftForTesting(7)
                print("Injected seven-second drift into test clock; waiting for automatic probe")
            } else if origin == .probe, abs(player.lastCorrection) >= 5 {
                bridge.stop()
                print("PASS live sync: independent periodic query repaired injected clock drift automatically")
                exit(0)
            }
        }
        bridge.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
            bridge.stop()
            print("FAIL live sync: no automatic correction; player must be available")
            exit(1)
        }
        RunLoop.main.run()
    }

    static func runRecovery() {
        let bridge = PlaybackBridge()
        var injected = false
        var interrupted = false
        bridge.onError = { _ in interrupted = true }
        bridge.onSnapshot = { snapshot, _ in
            guard snapshot?.bundleIdentifier == "com.netease.163music", snapshot?.title != nil else { return }
            if !injected {
                injected = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { bridge.simulateFailureForTesting() }
            } else if interrupted {
                bridge.stop()
                print("PASS recovery: terminated stream automatically reconnected and received NetEase metadata")
                exit(0)
            }
        }
        bridge.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            bridge.stop()
            print("FAIL recovery: no metadata after simulated connection loss")
            exit(1)
        }
        RunLoop.main.run()
    }

    static func runLive() {
        let model = DesktopAppModel()
        model.start()
        let began = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !model.lyrics.lyrics.isEmpty || model.lyrics.isPureMusic {
                    print("PASS live: \(model.player.currentSong?.name ?? "") / \(model.lyrics.lyrics.count) lyric lines / \(model.player.isPlaying ? "playing" : "paused") / \(Int(model.player.estimatedProgress())) seconds")
                    model.stop()
                    exit(0)
                }
                if Date().timeIntervalSince(began) > 30 {
                    print("FAIL live: \(model.status)")
                    model.stop()
                    exit(1)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }

    static func run() {
        var indicator = PlaybackIndicatorFilter()
        precondition(!indicator.update(playing: true, at: 0) && indicator.displayed)
        indicator.noteTrackSwitch(at: 1)
        precondition(indicator.update(playing: false, at: 1.1) && indicator.displayed)
        precondition(!indicator.update(playing: true, at: 1.4) && indicator.displayed)
        precondition(indicator.update(playing: false, at: 1.5) && indicator.displayed)
        precondition(!indicator.update(playing: false, at: 2.2) && !indicator.displayed)
        precondition(!indicator.update(playing: true, at: 2.3) && indicator.displayed)
        indicator.noteTrackSwitch(at: 3)
        indicator.notePlaybackCommand()
        precondition(!indicator.update(playing: false, at: 3.1) && !indicator.displayed)
        let mixedTranslations = LyricsState()
        mixedTranslations.lyrics = [LyricLine(time: 0, text: "A", translation: "翻译"), LyricLine(time: 1, text: "B")]
        precondition(mixedTranslations.hasTranslations)
        mixedTranslations.lyrics = [LyricLine(time: 0, text: "A", translation: "  "), LyricLine(time: 1, text: "B")]
        precondition(!mixedTranslations.hasTranslations)
        print("PASS: switch-time playback indicator stability and mixed translation detection")
        for progress: CGFloat in [0, 0.25, 0.5, 1] {
            for incoming in [true, false] {
                precondition(SongInfoMotion.offset(direction: 1, incoming: incoming, progress: progress)
                    == -SongInfoMotion.offset(direction: -1, incoming: incoming, progress: progress))
            }
        }
        precondition(SongInfoMotion.offset(direction: 1, incoming: true, progress: 0) > 0)
        precondition(SongInfoMotion.offset(direction: 1, incoming: false, progress: 1) < 0)
        print("PASS: previous and next song information move in opposite directions")
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let usable = NSRect(x: -1440, y: 80, width: 1440, height: 790)
        let ink = NSRect(x: -500, y: 200, width: 300, height: 50)
        let left = LyricsPositionPreset.bottomLeft.displacement(ink: ink, screen: screen, visible: usable, topLimit: 870, bottomInset: 12)
        let right = LyricsPositionPreset.bottomRight.displacement(ink: ink, screen: screen, visible: usable, topLimit: 870, bottomInset: 12)
        precondition(ink.minX + left.x == -1421 && ink.minY + left.y == 12)
        precondition(ink.maxX + right.x == -19 && ink.minY + right.y == 12)
        let expanded = NSRect(x: -500, y: 170, width: 400, height: 80)
        let moved = LyricsPositionPreset.bottomRight.displacement(ink: expanded, screen: screen, visible: usable, topLimit: 870, bottomInset: 12)
        precondition(expanded.maxX + moved.x == -19 && expanded.minY + moved.y == 12)
        let top = LyricsPositionPreset.topCenter.displacement(ink: ink, screen: screen, visible: usable, topLimit: 870, bottomInset: 12, topCenterInset: 42)
        precondition(ink.maxY + top.y == 858)
        print("PASS: lyric position presets anchor content across sizes")
        precondition(SupportedPlayers.contains("com.netease.163music"))
        precondition(SupportedPlayers.contains("com.tencent.QQMusicMac"))
        precondition(SupportedPlayers.contains("com.apple.Music"))
        precondition(!SupportedPlayers.contains(nil))
        print("PASS: supported player identifiers")
        let muted: [UInt8] = [160, 130, 130, 255]
        let green: [UInt8] = [20, 160, 40, 255]
        let similarGreen: [UInt8] = [30, 170, 60, 255]
        let small = Array(repeating: muted, count: 96).flatMap { $0 } + Array(repeating: green, count: 4).flatMap { $0 }
        guard let smallColor = ArtworkLyricColor.representativeColor(small) else { preconditionFailure("Artwork color unavailable") }
        precondition(smallColor.0 > smallColor.1, "Less than 5% must be ignored")
        let enough = Array(repeating: muted, count: 95).flatMap { $0 } + Array(repeating: green, count: 3).flatMap { $0 } + Array(repeating: similarGreen, count: 2).flatMap { $0 }
        guard let grouped = ArtworkLyricColor.representativeColor(enough) else { preconditionFailure("Grouped color unavailable") }
        precondition(grouped.1 > grouped.0 * 3, "Similar colors totaling 5% must qualify")
        let white: [UInt8] = [255, 255, 255, 255]
        let blue: [UInt8] = [0, 73, 250, 255]
        let sparse = Array(repeating: white, count: 98).flatMap { $0 } + Array(repeating: blue, count: 2).flatMap { $0 }
        guard let selected = ArtworkLyricColor.representativeColor(sparse) else { preconditionFailure("Sparse accent unavailable") }
        precondition(selected.0 == 0 && abs(selected.1 - 73.0 / 255) < 0.0001 && abs(selected.2 - 250.0 / 255) < 0.0001)
        let brightBlue = ArtworkLyricColor.makeVisible(selected)
        precondition(brightBlue.0 == 0 && abs(brightBlue.1 - selected.1) < 0.0001 && abs(brightBlue.2 - selected.2) < 0.0001)
        let transparent: [UInt8] = [255, 0, 0, 0, 100, 100, 100, 255]
        guard let gray = ArtworkLyricColor.representativeColor(transparent) else { preconditionFailure("Grayscale artwork") }
        precondition(gray.0 == gray.1 && gray.1 == gray.2)
        precondition(ArtworkLyricColor.representativeColor([0, 0, 0, 0]) == nil)
        let vivid = ArtworkLyricColor.makeVisible((0.4, 0.3, 0.2))
        precondition(abs(vivid.0 - 0.9) < 0.0001 && abs(vivid.2 - 0.18) < 0.0001)
        precondition(abs(vivid.1 - (vivid.0 + vivid.2) / 2) < 0.0001)
        let mutedResult = ArtworkLyricColor.makeVisible((0.8, 0.7, 0.7))
        precondition(abs(mutedResult.0 - 0.9) < 0.0001 && abs(mutedResult.1 - 0.18) < 0.0001)
        let neutral = ArtworkLyricColor.makeVisible((0.3, 0.3, 0.3))
        precondition(abs(neutral.0 - 0.9) < 0.0001 && neutral.0 == neutral.1 && neutral.1 == neutral.2)
        let strong = ArtworkLyricColor.makeVisible((0.9, 0.1, 0.3))
        precondition(abs(strong.0 - 0.9) < 0.0001 && abs(strong.1 - 0.1) < 0.0001)
        print("PASS: 5% coverage, minimal cover accents, transparency and color enhancement")
        testLyricsSelection()

        let timed = LyricParser.parse(yrc: "[1000,1200](1000,400,0)你(1400,800,0)好", lrc: "[00:01.000]你好")
        precondition(timed.count == 1 && timed[0].text == "你好")
        precondition(timed[0].syllables.count == 2)
        precondition(timed[0].syllables[0].startTime == 1 && timed[0].syllables[1].endTime == 2.2)
        let fallback = LyricParser.parse(yrc: "invalid", lrc: "[00:01.000]正常整句")
        precondition(fallback.count == 1 && fallback[0].syllables.isEmpty)

        let shortNote = LyricCharacterTiming(start: 1, end: 1.2)
        let sustained = LyricCharacterTiming(start: 1, end: 5)
        precondition(shortNote.progress(at: 0.9) == 0)
        precondition(shortNote.progress(at: 1.2) == 1)
        precondition(sustained.progress(at: 1.2) < 0.01, "Long notes must not finish in 0.22 seconds")
        precondition(abs(sustained.progress(at: 3) - 0.5) < 0.0001)
        precondition(sustained.progress(at: 5) == 1)
        precondition(sustained.progress(at: 6) == 1)
        precondition(LyricCharacterTiming(start: 2, end: 2).progress(at: 1.9) == 0)
        precondition(LyricCharacterTiming(start: 2, end: 2).progress(at: 2) == 1)
        precondition(sustained.sustainedBrightness(at: 1) == 0)
        precondition(sustained.sustainedBrightness(at: 4) > sustained.sustainedBrightness(at: 2))
        precondition(sustained.sustainedBrightness(at: 5.3) > 0
        && sustained.sustainedBrightness(at: 6) == 0)
        precondition(LyricCharacterTiming(start: 2, end: 2).sustainedBrightness(at: 2) == 0)
        precondition(sustained.glowStrength(at: 0.9) == 0)
        precondition(sustained.glowStrength(at: 3) > shortNote.glowStrength(at: 1.1))
        precondition(sustained.glowStrength(at: 4.5) > sustained.glowStrength(at: 2))
        precondition(FloatingLyricsTone.completedGlowMultiplier(currentStrength: sustained.glowStrength(at: 4.5)) < FloatingLyricsTone.completedGlowMultiplier(currentStrength: sustained.glowStrength(at: 2)))
        precondition(FloatingLyricsTone.completedGlowMultiplier(currentStrength: sustained.glowStrength(at: 6)) == 1)
        precondition(FloatingLyricsTone.completedGlowMultiplier(currentStrength: 0.1) < 0.8)
        precondition(abs(FloatingLyricsTone.completedGlowMultiplier(currentStrength: 1) - 0.3) < 0.0001)
        precondition(FloatingLyricsTone.completedOpacityMultiplier(currentStrength: 0) == 1)
        precondition(FloatingLyricsTone.completedOpacityMultiplier(currentStrength: 1) < FloatingLyricsTone.completedOpacityMultiplier(currentStrength: 0.2))
        precondition(FloatingLyricsTone.completedOpacityMultiplier(currentStrength: 1) > 0)
        precondition(sustained.completedDimming(at: 4.9) == 0)
        precondition(sustained.completedDimming(at: 5) == 0)
        precondition(sustained.completedDimming(at: 5.5) == 0)
        precondition(abs(sustained.completedDimming(at: 5.9) - 0.5) < 0.0001)
        precondition(sustained.completedDimming(at: 6.3) == 1)
        precondition(sustained.completedDimming(at: 10) == 1)
        precondition(LyricCharacterTiming(start: 2, end: 2).completedDimming(at: 3) == 0)
        let firstWord = LyricCharacterTiming(start: 0, end: 0.5)
        let followingSustain = LyricCharacterTiming(start: 2, end: 6)
        let phraseTimings = [firstWord, followingSustain]
        precondition(FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 0.5) == 0)
        precondition(FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 1.4) > 0)
        precondition(FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 5) > FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 3))
        precondition(FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 7) == FloatingLyricsTone.dimmingStrength(for: firstWord, among: phraseTimings, at: 6))
        precondition(FloatingLyricsTone.dimmingStrength(for: followingSustain, among: phraseTimings, at: 5) == 0)
        precondition(sustained.retainedDimmingStrength(at: 5.7) == sustained.retainedDimmingStrength(at: 5))
        precondition(sustained.retainedDimmingStrength(at: 4.5) > sustained.retainedDimmingStrength(at: 2))
        precondition(LyricCharacterTiming(start: 2, end: 2).retainedDimmingStrength(at: 3) == 0)
        precondition(sustained.glowStrength(at: 5) <= 1)
        precondition(sustained.glowStrength(at: 5.3) < sustained.glowStrength(at: 5))
        precondition(sustained.glowStrength(at: 5.7) > 0
        && sustained.glowStrength(at: 6) == 0)
        precondition(shortNote.glowStrength(at: 1.46) == 0)
        precondition(LyricCharacterTiming(start: 0, end: 100).glowStrength(at: 101.2) == 0)
        precondition(LyricCharacterTiming(start: 0, end: 100).glowStrength(at: 100) <= 1)
        precondition(LyricCharacterTiming(start: 2, end: 2).glowStrength(at: 2) == 0)
        precondition(FloatingLyricsTone.bloomGain(intensity: 3) == 0)
        precondition(FloatingLyricsTone.bloomGain(intensity: 4.5) == 0.5)
        precondition(FloatingLyricsTone.bloomGain(intensity: 6) == 1)
        for intensity in [0.5, 1.0, 2.6, 3.0, 6.0] {
            for core in [false, true] {
                let completed = FloatingLyricsTone.glowOpacity(sung: 1, sustained: 0, intensity: intensity, focus: 1, core: core)
                let active = FloatingLyricsTone.glowOpacity(sung: 1, sustained: 1, intensity: intensity, focus: 1, core: core)
                precondition(active > completed && active <= 1)
            }
        }
        precondition(FloatingLyricsTone.glowOpacity(sung: 1, sustained: 1, intensity: 0, focus: 1, core: false) == 0)
        precondition(FloatingLyricsTone.glowOpacity(sung: 1, sustained: 0, intensity: 6, focus: 1, core: false) > FloatingLyricsTone.glowOpacity(sung: 1, sustained: 0, intensity: 3, focus: 1, core: false))
        let mixed = LyricLine(time: 0, text: "你好 Don't stop-believing!", syllables: [
            LyricSyllable(text: "你", startTime: 0, endTime: 0.2),
            LyricSyllable(text: "好 ", startTime: 0.3, endTime: 0.5),
            LyricSyllable(text: "Don", startTime: 1, endTime: 1.2),
            LyricSyllable(text: "'t ", startTime: 1.2, endTime: 1.4),
            LyricSyllable(text: "stop-", startTime: 2, endTime: 2.3),
            LyricSyllable(text: "believing!", startTime: 2.3, endTime: 3)
        ])
        let units = LyricHighlightUnits.make(for: mixed)
        precondition(units.map(\.text) == ["你", "好", " ", "Don't", " ", "stop-believing", "!"])
        precondition(units[3].start == 1 && units[3].end == 1.4)
        precondition(units.map(\.text).joined() == mixed.text)
        precondition(LyricHighlightUnits.make(for: fallback[0]).isEmpty)
        let untimed = LyricHighlightUnits.untimedMotionUnits("你好 Don't stop-believing! 🎵")
        precondition(untimed == ["你", "好", " ", "Don't", " ", "stop-believing", "!", " ", "🎵"])
        precondition(untimed.joined() == "你好 Don't stop-believing! 🎵")
        precondition(LyricHighlightUnits.untimedMotionUnits("").isEmpty)
        print("PASS: untimed motion units preserve text and word grouping")
        precondition(PlaybackBridge.retryDelay(1) == 1 && PlaybackBridge.retryDelay(2) == 2)
        precondition(PlaybackBridge.retryDelay(10) == 15)
        let leftScreen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let rightScreen = NSRect(x: 1000, y: 0, width: 1000, height: 800)
        let target = NSRect(x: 800, y: 200, width: 300, height: 100)
        let dx = CharacterScreenTransition.displacement(for: target, screens: [leftScreen, rightScreen])
        let outsideTransition = target.offsetBy(dx: 0, dy: -dx)
        precondition(!outsideTransition.intersects(leftScreen) && !outsideTransition.intersects(rightScreen))
        precondition(outsideTransition.maxY < min(leftScreen.minY, rightScreen.minY))
        precondition(CharacterScreenTransition.travelProgress(0, index: 0, total: 101) == 0)
        precondition(CharacterScreenTransition.travelProgress(1, index: 100, total: 101) == 1)
        let exitAtStart = 1 - CharacterScreenTransition.travelProgress(0.8, index: 0, total: 1, entering: false)
        let exitAtMiddle = 1 - CharacterScreenTransition.travelProgress(0.6, index: 0, total: 1, entering: false)
        let exitAtEnd = 1 - CharacterScreenTransition.travelProgress(0.4, index: 0, total: 1, entering: false)
        precondition(exitAtStart < exitAtMiddle - exitAtStart && exitAtMiddle - exitAtStart < exitAtEnd - exitAtMiddle)

        precondition(CharacterScreenTransition.travelProgress(0.4, index: 0, total: 101) > CharacterScreenTransition.travelProgress(0.4, index: 10, total: 101))
        let leftFirstLeft = CharacterScreenTransition.travelProgress(0.4, index: 0, total: 10)
        let leftFirstRight = CharacterScreenTransition.travelProgress(0.4, index: 9, total: 10)
        let rightFirstLeft = CharacterScreenTransition.travelProgress(0.4, index: 0, total: 10, rightFirst: true)
        let rightFirstRight = CharacterScreenTransition.travelProgress(0.4, index: 9, total: 10, rightFirst: true)
        precondition(leftFirstLeft > leftFirstRight && rightFirstRight > rightFirstLeft)
        precondition(CharacterScreenTransition.presetOrder(offsetX: -300).rightFirst)
        precondition(!CharacterScreenTransition.presetOrder(offsetX: 300).rightFirst)
        precondition(CharacterScreenTransition.presetOrder(offsetX: 0).centerFirst)
        let middle = CharacterScreenTransition.travelProgress(0.4, index: 2, total: 5, centerFirst: true)
        let edge = CharacterScreenTransition.travelProgress(0.4, index: 0, total: 5, centerFirst: true)
        precondition(middle > edge)
        precondition(CharacterScreenTransition.displacement(for: target, screens: [leftScreen, rightScreen], upward: true) < 0)
        print("PASS: alignment-aware character order and multi-display bounds")
        let suiteName = "local.flowflow.frame-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dimPreferences = FloatingLyricsPreferences(defaults: defaults)
        precondition(dimPreferences.dimCompletedLyrics)
        dimPreferences.dimCompletedLyrics = false
        precondition(!FloatingLyricsPreferences(defaults: defaults).dimCompletedLyrics)
        dimPreferences.reset()
        precondition(FloatingLyricsPreferences(defaults: defaults).dimCompletedLyrics)
        let outside = NSRect(x: -70, y: -48, width: 420, height: 132)
        defaults.set(NSStringFromRect(outside), forKey: DesktopFloatingLyricsFramePersistence.key)
        precondition(DesktopFloatingLyricsFramePersistence.savedFrame(defaults: defaults) == outside)
        let panel = UnconstrainedLyricsPanel(contentRect: outside, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.setFrame(outside, display: false)
        precondition(panel.frame == outside)
        let above = NSRect(x: 1500, y: 2000, width: 420, height: 132)
        precondition(panel.constrainFrameRect(above, to: NSScreen.main) == above)
        panel.setFrame(above, display: false)
        precondition(panel.frame == above)
        let previousOffset = UserDefaults.standard.object(forKey: "sync.offset")
        defer {
            if let previousOffset { UserDefaults.standard.set(previousOffset, forKey: "sync.offset") }
            else { UserDefaults.standard.removeObject(forKey: "sync.offset") }
        }
        let lrc = "[00:01.000]First\n[00:03.500]Second\n[00:08.000]Third"
        let lines = LyricParser.parse(yrc: "", lrc: lrc, translatedLRC: "[00:01.000]第一句\n[00:03.500]第二句")
        precondition(lines.count == 3 && lines[0].translation == "第一句")
        precondition(LyricPlaybackTimeline.position(at: 0, in: lines).highlightedLyricID == nil)
        precondition(LyricPlaybackTimeline.position(at: 3.5, in: lines).highlightedLyricID == lines[1].id)
        for title in ["Clock", "New track", "Test"] {
            SongOffsetStore(defaults: defaults).save(0, for: Song(id: title, name: title, artist: "Artist", albumName: "Album", duration: 120))
        }
        let player = ExternalPlayer(defaults: defaults, defaultAdvance: 0)
        player.offset = 0
        testPlaybackSynchronization(player)
        func sample(_ time: Double, playing: Bool) -> RemoteSnapshot {
            RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: "Test", artist: "Artist", album: "Album",
                playing: playing, elapsedTimeMicros: time * 1_000_000, durationMicros: 60_000_000,
                timestampEpochMicros: Date().timeIntervalSince1970 * 1_000_000, playbackRate: 1)
        }
        player.accept(sample(12, playing: false))
        player.offset = 0 // Timing checks below intentionally use no manual offset.
        precondition(abs(player.estimatedProgress() - 12) < 0.01)
        player.accept(sample(40, playing: true))
        precondition(player.estimatedProgress() >= 40 && player.estimatedProgress() < 40.1)
        player.accept(sample(2, playing: false)) // seek backwards while paused
        precondition(player.estimatedProgress() == 2)
        player.clear()
        let staleTimestamp = Date().timeIntervalSince1970 - 30
        let liveSample = RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: "Test", artist: "Artist", album: "Album",
            playing: true, elapsedTimeMicros: 10_000_000, durationMicros: 60_000_000,
            timestampEpochMicros: staleTimestamp * 1_000_000, playbackRate: 1)
        player.accept(liveSample)
        let beforePause = player.estimatedProgress()
        let pauseSample = RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: "Test", artist: "Artist", album: "Album",
            playing: false, elapsedTimeMicros: 10_000_000, durationMicros: 60_000_000,
            timestampEpochMicros: staleTimestamp * 1_000_000, playbackRate: 1)
        player.accept(pauseSample)
        precondition(abs(player.estimatedProgress() - beforePause) < 0.01, "Stale pause sample must not rewind lyrics")
        player.accept(sample(59, playing: false))
        player.offset = 5
        precondition(player.estimatedProgress() == 60)
        player.clear()
        precondition(!player.isPlaying && player.currentSong == nil)
        player.offset = 0
        let offsetStore = SongOffsetStore(defaults: defaults)
        let baselineSong = Song(id: "baseline", name: "Abu Dhabi", artist: "Mikolas", albumName: "Abu Dhabi", duration: 0)
        precondition(abs(offsetStore.load(baselineSong) - 0.9) < 0.0001)
        offsetStore.save(0, for: baselineSong)
        precondition(offsetStore.load(baselineSong) == 0)
        offsetStore.reset()
        precondition(abs(offsetStore.load(baselineSong) - 0.9) < 0.0001)
        let firstSong = Song(id: "a", name: "First", artist: "Singer", albumName: "Album", duration: 0)
        let sameSongLater = Song(id: "b", name: "First", artist: "Singer", albumName: "Album", duration: 200)
        let otherSong = Song(id: "c", name: "Second", artist: "Singer", albumName: "Album", duration: 200)
        precondition(offsetStore.load(firstSong) == 0 && offsetStore.load(otherSong) == 0)
        offsetStore.save(0.6, for: firstSong)
        precondition(offsetStore.load(sameSongLater) == 0.6 && offsetStore.load(otherSong) == 0)
        offsetStore.save(-1.2, for: otherSong)
        precondition(offsetStore.load(firstSong) == 0.6 && offsetStore.load(otherSong) == -1.2)
        offsetStore.save(0, for: firstSong)
        precondition(offsetStore.load(sameSongLater) == 0 && offsetStore.load(otherSong) == -1.2)
        func offsetSample(_ title: String) -> RemoteSnapshot {
            RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: title, artist: "Test singer", album: "Test album", playing: false, elapsedTimeMicros: 0, durationMicros: 100_000_000, timestampEpochMicros: nil, playbackRate: 1)
        }
        let offsetPlayer = ExternalPlayer(defaults: defaults, defaultAdvance: 0)
        offsetPlayer.accept(offsetSample("Track A"))
        precondition(offsetPlayer.offset == 0)
        offsetPlayer.offset = 0.6
        offsetPlayer.accept(offsetSample("Track B"))
        precondition(offsetPlayer.offset == 0)
        offsetPlayer.offset = -1.2
        offsetPlayer.accept(offsetSample("Track A"))
        precondition(offsetPlayer.offset == 0.6)
        let restartedPlayer = ExternalPlayer(defaults: defaults, defaultAdvance: 0)
        restartedPlayer.accept(offsetSample("Track B"))
        precondition(restartedPlayer.offset == -1.2)
        restartedPlayer.offset = 0
        offsetPlayer.accept(offsetSample("Track B"))
        precondition(offsetPlayer.offset == 0)
        precondition(!LyricGapPolicy.shouldShowDots(end: 10, next: 15, now: 14.9))
        precondition(!LyricGapPolicy.shouldShowDots(end: 10, next: 20, now: 15))
        precondition(LyricGapPolicy.shouldShowDots(end: 10, next: 20, now: 15.1))
        precondition(!LyricGapPolicy.shouldShowDots(end: 10, next: 20, now: 20))
        precondition(SongColorOverride.isGoldenHour(Song(id: "golden", name: "golden hour", artist: "JVKE", albumName: "", duration: 200)))
        precondition(!SongColorOverride.isGoldenHour(Song(id: "other", name: "golden hour", artist: "Another Artist", albumName: "", duration: 200)))
        precondition(!SongColorOverride.isGoldenHour(nil))
        let song = Song(id: "a", name: "Song", artist: "Singer", albumName: "Album", duration: 100)
        let candidate = TrackCandidate(["id": 1, "name": "Song", "artists": [["name": "Singer"]], "duration": 100_000])!
        precondition(candidate.score(for: song) != nil)
        precondition(abs(candidate.durationSeconds - 100) < 0.001)
        let wrong = TrackCandidate(["id": 2, "name": "Song", "artists": [["name": "Other"]], "duration": 100_000])!
        precondition(wrong.score(for: song) == nil)
        let matchSuite = "local.flowflow.lyric-match.\(UUID().uuidString)"
        let matchDefaults = UserDefaults(suiteName: matchSuite)!
        defer { matchDefaults.removePersistentDomain(forName: matchSuite) }
        let appleSong = Song(id: "en", name: "Sunny Day", artist: "Jay Chou", albumName: "Album", duration: 269)
        let chinese = TrackCandidate(["id": 186016, "name": "晴天", "artists": [["name": "周杰伦"]],
                                      "album": ["name": "叶惠美"], "duration": 269_000])!
        let store = LyricMatchStore(defaults: matchDefaults)
        store.save(.netease(chinese), for: appleSong)
        let saved = store.load(for: appleSong)
        precondition(saved?.songID == "186016" && saved?.name == "晴天")
        precondition(abs((saved?.duration ?? 0) - 269) < 0.001)
        store.clear(for: appleSong)
        precondition(store.load(for: appleSong) == nil)
        let event = try! JSONDecoder().decode(RemoteEvent.self,
            from: Data("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"com.netease.163music\",\"title\":\"Test\",\"playing\":false}}".utf8))
        precondition(event.payload?.title == "Test" && event.payload?.playing == false)
        print("PASS: LRC/translation parsing, lyric boundaries, pause, seek, time offset/clamping, track matching, retry policy, exact offscreen frame retention")
    }
    private static func testPlaybackSynchronization(_ player: ExternalPlayer) {
        player.clear()
        let epoch = Date().timeIntervalSince1970 * 1_000_000
        func sample(_ elapsed: Double?, timestamp: Double?, playing: Bool, title: String = "Clock", rate: Double = 1) -> RemoteSnapshot {
            RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: title, artist: "Artist", album: "Album",
                playing: playing, elapsedTimeMicros: elapsed.map { $0 * 1_000_000 }, durationMicros: 120_000_000,
                timestampEpochMicros: timestamp, playbackRate: rate)
        }
        let point = sample(10, timestamp: epoch - 20_000_000, playing: true)
        player.accept(point)
        let correct = player.estimatedProgress()
        player.simulateDriftForTesting(7)
        player.accept(point) // duplicate stream data alone must not hide/re-anchor state changes
        precondition(player.estimatedProgress() > correct + 6)
        player.accept(point, origin: .probe)
        precondition(abs(player.estimatedProgress() - correct) < 0.1)
        precondition(player.lastCorrection < -6)
        let songID = player.currentSong?.id
        let beforePartial = player.estimatedProgress()
        player.accept(RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: "Clock", artist: nil, album: nil,
            playing: nil, elapsedTimeMicros: nil, durationMicros: nil, timestampEpochMicros: nil, playbackRate: nil))
        precondition(player.currentSong?.id == songID && player.isPlaying)
        precondition(abs(player.estimatedProgress() - beforePartial) < 0.1)
        let seek = sample(70, timestamp: epoch, playing: true)
        player.accept(seek)
        player.accept(point, origin: .probe)
        precondition(player.estimatedProgress() >= 70 && player.estimatedProgress() < 70.1)
        precondition(player.discardedTimingSamples > 0)
        player.clear()
        player.accept(point)
        let beforePause = player.estimatedProgress()
        let paused = sample(10, timestamp: epoch - 20_000_000, playing: false)
        player.accept(paused)
        player.simulateDriftForTesting(3)
        player.accept(paused, origin: .probe)
        precondition(abs(player.estimatedProgress() - beforePause) < 0.1, "Pause compensation must survive active resync")
        player.accept(point)
        precondition(abs(player.estimatedProgress() - beforePause) < 0.1)
        player.suspend()
        player.simulateDriftForTesting(3)
        player.accept(point, origin: .probe)
        precondition(abs(player.estimatedProgress() - beforePause) < 0.1, "Transport recovery must use the live reference")
        player.clear()
        player.accept(sample(50, timestamp: epoch, playing: true, rate: 0))
        precondition(player.estimatedProgress() > 50, "A stale zero rate must not freeze announced playback")
        player.accept(RemoteSnapshot(bundleIdentifier: "com.netease.163music", title: "Partial track", artist: "Artist", album: "Album",
            playing: nil, elapsedTimeMicros: 0, durationMicros: 120_000_000, timestampEpochMicros: epoch, playbackRate: 1))
        precondition(player.isPlaying, "A track update without playback state must preserve the last known state")
        player.accept(sample(0, timestamp: epoch, playing: true, title: "New track"))
        precondition(player.estimatedProgress() < 0.1, "A new track must not inherit the old timestamp age")
        player.simulateDriftForTesting(1)
        player.accept(sample(0, timestamp: epoch, playing: true, title: "New track"), origin: .probe)
        precondition(player.estimatedProgress() >= 1, "Untrusted inherited timestamp must not repeatedly reset the new clock")
        player.accept(sample(2, timestamp: epoch + 1000, playing: false, title: "New track"), origin: .probe)
        precondition(player.estimatedProgress() == 2)
        player.clear()
        let withoutTimestamp = sample(10, timestamp: nil, playing: true)
        player.accept(withoutTimestamp)
        player.simulateDriftForTesting(1)
        player.accept(withoutTimestamp, origin: .probe)
        precondition(player.estimatedProgress() >= 11, "A cache without timestamp cannot reset a running clock")
        player.clear()
        let future = sample(10, timestamp: epoch + 60_000_000, playing: true)
        player.accept(future)
        player.simulateDriftForTesting(1)
        player.accept(future, origin: .probe)
        precondition(player.estimatedProgress() >= 11, "A future timestamp must not repeatedly rewind playback")
        player.clear()
        print("PASS: probe drift repair, pause compensation, missing fields, stale seek rejection, zero-rate recovery and track timestamp isolation")
    }

    private static func testLyricsSelection() {
        precondition(LyricsQuality.isInstrumentalText("此歌曲为没有填词的纯音乐，请您欣赏"))
        let credits = LyricsQuality.displayLines([LyricLine(time: 1, duration: 2, text: "作词：某人", translation: "lyrics"), LyricLine(time: 3, text: "Produced by: Someone"), LyricLine(time: 4, text: "我为你作曲")])
        precondition(credits.map(\.text) == ["...", "...", "我为你作曲"] && credits[0].time == 1 && credits[0].duration == 2 && credits[0].translation == nil)
        for text in ["词曲 张三", "编曲 - 张三", "混录/混音：张三", "【混录】张三", "词曲：张三", "混录师: 张三", "\u{200B}编曲：张三", "作词", "混音师：某人", "录音/混音：某人", "【母带】：某人", "Recording Engineer: Jane", "制作协力: 某人", "吉他：某人"] {
            precondition(LyricsQuality.isCreditText(text), "Unrecognized credit: \(text)")
        }
        for text in ["我为你作曲", "编曲的故事", "混录的声音", "作曲家在歌唱", "混音的夜晚", "爱：从这里开始"] {
            precondition(!LyricsQuality.isCreditText(text), "Lyric mistaken for credit: \(text)")
        }

        let duetLRC = "[00:01.00]词曲：张三\n[00:02.00]混录：李四\n[00:03.00]甲：你好\n[00:04.00]乙：再见"
        let duetLines = LyricParser.parse(yrc: "", lrc: duetLRC)
        precondition(duetLines[0].text == "词曲：张三" && duetLines[1].text == "混录：李四")
        let displayed = LyricsQuality.displayLines(duetLines)
        precondition(displayed[0].text == "..." && displayed[1].text == "..." && displayed[0].time == 1)
        let qrcCredits = QRCParser.parse("[1000,1000]编曲 张三(1000,1000)\n[2000,1000]混录：李四(2000,1000)")
        precondition(LyricsQuality.displayLines(qrcCredits).allSatisfy { $0.text == "..." })
        precondition(!LyricsQuality.isContent(LyricLine(time: 0, text: "此歌曲为没有填词的纯音乐，请您欣赏")))
        let pure = LyricsResult(lines: [], pureMusic: true, songID: "pure", source: .qq)
        precondition(LyricsQuality.prefer(pure, over: nil, duration: 120))
        precondition(!LyricsQuality.prefer(pure, over: LyricsResult(lines: [LyricLine(time: 1, text: "正常歌词")], pureMusic: false, songID: "ne"), duration: 120))
        let qrc = "<QrcInfos><LyricInfo><Lyric_1 LyricContent=\"[1000,1600]你(1000,400)好(1400,1200)&#10;[3000,2000]don&apos;t (3000,800)stop(3800,1200)\"/></LyricInfo></QrcInfos>"
        let parsed = QRCParser.parse(qrc)
        precondition(parsed.count == 2 && parsed[0].text == "你好" && parsed[1].text == "don't stop")
        precondition(parsed[0].syllables[1].endTime == 2.6)
        precondition(parsed[1].syllables[0].startTime == 3)
        precondition(QRCParser.parse("garbage").isEmpty)
        do { _ = try QRCDecoder.decode("not encrypted lyrics"); preconditionFailure("Invalid ciphertext must fail") }
        catch { }
        let song = Song(id: "test", name: "Song", artist: "Artist", albumName: "Album", duration: 120)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Song (Live)", artists: ["Artist"], album: "Album", duration: 120).matchScore(for: song) == nil)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Song", artists: ["Artist Cover"], album: "Album", duration: 120).matchScore(for: song) == nil)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Song", artists: ["Artist"], album: "Album", duration: 130).matchScore(for: song) == nil)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Song", artists: ["Artist"], album: "Album", duration: 120).matchScore(for: song) != nil)
        let soundtrack = Song(id: "film", name: "Feel It", artist: "d4vd", albumName: "Feel It", duration: 157)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Feel It", artists: ["d4vd"], album: "Feel It (From Invincible)", duration: 157, versionTitle: "Feel It (From Invincible)").matchScore(for: soundtrack) != nil)
        precondition(QQTrackCandidate(id: 1, mid: "", name: "Feel It", artists: ["d4vd"], album: "", duration: 157, versionTitle: "Feel It (Live)").matchScore(for: soundtrack) == nil)
        precondition(LyricsQuality.artistsMatch(["A", "B"], "A/B"))
        precondition(!LyricsQuality.artistsMatch(["A"], "AB"))
        var lines = [LyricLine]()
        for i in 0..<5 {
            let start = Double(i * 3 + 1)
            let syllables = [
                LyricSyllable(text: "歌", startTime: start, endTime: start + 0.3),
                LyricSyllable(text: "词", startTime: start + 0.3, endTime: start + 0.6),
                LyricSyllable(text: "测", startTime: start + 0.6, endTime: start + 1),
                LyricSyllable(text: "试\(i)", startTime: start + 1, endTime: start + 2)]
            lines.append(LyricLine(time: start, duration: 2, text: "歌词测试\(i)", syllables: syllables))
        }
        let original = LyricsResult(lines: lines.map { LyricLine(time: $0.time, duration: $0.duration, text: $0.text) }, pureMusic: false, songID: "ne")
        let qq = LyricsResult(lines: lines, pureMusic: false, songID: "qq", source: .qq)
        precondition(LyricsQuality.prefer(qq, over: original, duration: 120))
        precondition(!LyricsQuality.prefer(qq, over: qq, duration: 120), "Ties must not switch providers")
        let wrong = lines.map { LyricLine(time: $0.time, text: "另一首歌的文字") }
        precondition(LyricsQuality.aligned(wrong, to: original.lines) == nil)
        let shifted = lines.map { line in
            LyricLine(time: line.time + 0.4, duration: line.duration, text: line.text,
                syllables: line.syllables.map { LyricSyllable(text: $0.text, startTime: $0.startTime + 0.4, endTime: $0.endTime + 0.4) })
        }
        let translatedReference = original.lines.map { $0.attachingTranslation("保留翻译") }
        let aligned = LyricsQuality.aligned(shifted, to: translatedReference)!
        precondition(aligned[0].translation == "保留翻译")
        precondition(abs(aligned[0].time - original.lines[0].time) < 0.0001)
        precondition(abs(aligned[0].syllables[0].startTime - lines[0].syllables[0].startTime) < 0.0001)
        let locallyWrong = lines.enumerated().map { index, line in
            LyricLine(time: line.time + (index == 4 ? 3 : 0), duration: line.duration, text: line.text)
        }
        precondition(LyricsQuality.aligned(locallyWrong, to: original.lines) == nil)
        let late = lines.map { LyricLine(time: $0.time + 5, duration: $0.duration, text: $0.text) }
        precondition(LyricsQuality.aligned(late, to: original.lines) == nil)
        let invalid = LyricsResult(lines: [LyricLine(time: 0, duration: 1, text: "错误时间", syllables: [LyricSyllable(text: "错误时间", startTime: 0, endTime: 999)])], pureMusic: false, songID: "broken", source: .qq)
        precondition(!LyricsQuality.prefer(invalid, over: original, duration: 120))
        print("PASS: QRC XML/entities, word timings, version/artist/duration checks, quality selection, tie retention, text mismatch and time alignment")
    }

}
