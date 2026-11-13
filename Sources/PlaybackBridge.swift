import Foundation
import Observation
import AppKit

struct RemoteSnapshot: Codable, Sendable {
    let bundleIdentifier: String?
    let title: String?
    let artist: String?
    let album: String?
    let playing: Bool?
    let elapsedTimeMicros: Double?
    let durationMicros: Double?
    let timestampEpochMicros: Double?
    let playbackRate: Double?
}

struct RemoteEvent: Decodable {
    let type: String
    let payload: RemoteSnapshot?
}

struct Song: Equatable, Sendable {
    let id: String
    let name: String
    let artist: String
    let albumName: String
    let duration: Double
    var album: Album? { nil }
    struct Album { let artworkURL: URL? }
}

enum PlaybackSampleOrigin: String, Sendable { case stream, probe }

struct SongOffsetStore {
    static let key = "sync.songOffsets"
    let defaults: UserDefaults
    private static let baseline: [String: Double] = {
        guard let url = Bundle.main.url(forResource: "DefaultSongOffsets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let offsets = try? PropertyListDecoder().decode([String: Double].self, from: data) else { return [:] }
        return offsets
    }()
    private func identity(_ song: Song) -> String {
        // Duration can arrive late or change between player samples.
        let fields = [song.name, song.artist, song.albumName].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
    }
    func load(_ song: Song) -> Double {
        let id = identity(song)
        let value = (defaults.dictionary(forKey: Self.key)?[id] as? NSNumber)?.doubleValue ?? Self.baseline[id] ?? 0
        return value.isFinite ? min(10, max(-10, value)) : 0
    }
    func reset() { defaults.removeObject(forKey: Self.key) }
    func save(_ value: Double, for song: Song) {
        guard value.isFinite else { return }
        var offsets = defaults.dictionary(forKey: Self.key) ?? [:]
        let id = identity(song)
        if abs(value - (Self.baseline[id] ?? 0)) < 0.0001 { offsets.removeValue(forKey: id) }
        else { offsets[id] = min(10, max(-10, value)) }
        defaults.set(offsets, forKey: Self.key)
    }
}

@MainActor @Observable final class ExternalPlayer {
    var currentSong: Song?
    var isPlaying = false
    var progress = 0.0
    private var anchor = 0.0
    private var sampledAt = ProcessInfo.processInfo.systemUptime
    private var rate = 1.0
    private var lastTimestamp: Double?
    private var lastElapsed: Double?
    private var timestampAdjustment = 0.0
    private var inheritedTimestamp: Double?
    private var transportSuspended = false
    private(set) var lastCorrection = 0.0
    private(set) var lastSampleOrigin = PlaybackSampleOrigin.stream
    private(set) var discardedTimingSamples = 0
    private let offsetStore: SongOffsetStore
    private var loadingOffset = false
    private let defaultAdvance: Double
    init(defaults: UserDefaults = .standard, defaultAdvance: Double = 0.2) {
        offsetStore = SongOffsetStore(defaults: defaults)
        self.defaultAdvance = defaultAdvance
    }
    var offset = 0.0 {
        didSet {
            if !loadingOffset, let song = currentSong { offsetStore.save(offset, for: song) }
            tick()
        }
    }

    func restoreDefaultOffsets() {
        offsetStore.reset()
        loadingOffset = true
        offset = currentSong.map { offsetStore.load($0) } ?? 0
        loadingOffset = false
    }

    func accept(_ snapshot: RemoteSnapshot, origin: PlaybackSampleOrigin = .stream) {
        let previous = currentSong
        let previousRawTime = rawProgress()
        let wasPlaying = isPlaying
        let title = snapshot.title ?? previous?.name ?? ""
        let sameTitle = previous?.name == title
        let artist = snapshot.artist ?? (sameTitle ? previous?.artist : nil) ?? ""
        let album = snapshot.album ?? (sameTitle ? previous?.albumName : nil) ?? ""
        let sameIdentity = previous?.name == title && previous?.artist == artist && previous?.albumName == album
        let reportedDuration = (snapshot.durationMicros ?? 0) / 1_000_000
        let duration = reportedDuration.isFinite && reportedDuration > 0 ? reportedDuration : (sameIdentity ? previous?.duration ?? 0 : 0)
        currentSong = Song(id: "\(title)|\(artist)|\(album)|\(Int(duration))",
                           name: title, artist: artist, albumName: album, duration: duration)
        let sameSong = previous?.id == currentSong?.id
        if !sameIdentity, let song = currentSong {
            loadingOffset = true
            offset = offsetStore.load(song)
            loadingOffset = false
        }
        let nextPlaying = snapshot.playing ?? wasPlaying
        let reportedRate = snapshot.playbackRate ?? 1
        // NetEase can announce playing=true before replacing its cached zero rate.
        let nextRate = reportedRate.isFinite && reportedRate > 0 ? reportedRate : 1
        let timestamp = snapshot.timestampEpochMicros.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let elapsed = snapshot.elapsedTimeMicros.flatMap { $0.isFinite && $0 >= 0 ? $0 / 1_000_000 : nil }
        let age = timestamp.map { max(0, Date().timeIntervalSince1970 - $0 / 1_000_000) } ?? 0
        let duplicate = sameSong && elapsed != nil && lastElapsed == snapshot.elapsedTimeMicros
            && (lastTimestamp == timestamp || timestamp == nil)
        let trustworthyTimestamp = timestamp.map { $0 / 1_000_000 <= Date().timeIntervalSince1970 + 2 } ?? false
        let older = sameSong && timestamp != nil && lastTimestamp != nil && timestamp! < lastTimestamp! - 1000
        var corrected = sameSong ? previousRawTime : 0

        if !sameSong {
            timestampAdjustment = 0
            inheritedTimestamp = previous != nil && timestamp != nil && lastTimestamp != nil
                && timestamp! <= lastTimestamp! ? timestamp : nil
        }
        if let elapsed, !older {
            if let timestamp, inheritedTimestamp != timestamp { inheritedTimestamp = nil }
            let projected = elapsed + (nextPlaying && inheritedTimestamp == nil ? age * nextRate : 0)
            if duplicate {
                // Keep a correction for real pauses when the provider reuses its
                // timestamp. A fresh probe can then repair drift without counting
                // the paused interval as playback.
                if inheritedTimestamp != nil || !trustworthyTimestamp {
                    // No valid absolute reference exists for this new track yet.
                    corrected = previousRawTime
                } else if wasPlaying != nextPlaying && !transportSuspended {
                    timestampAdjustment = previousRawTime - projected
                    corrected = previousRawTime
                } else if origin == .probe || transportSuspended {
                    let reference = max(0, projected + timestampAdjustment)
                    corrected = abs(reference - previousRawTime) >= 0.12 ? reference : previousRawTime
                }
            } else {
                timestampAdjustment = 0
                corrected = max(0, projected)
            }
            lastElapsed = snapshot.elapsedTimeMicros
            if !duplicate || timestamp != nil { lastTimestamp = timestamp }
        } else if older {
            // A delayed cache read must not rewind a newer seek or progress point.
            discardedTimingSamples += 1
        }
        if sameSong && abs(corrected - previousRawTime) >= 0.25 {
            lastCorrection = corrected - previousRawTime
            NSLog("Flowflow timeline corrected by %+.3fs from %@", lastCorrection, origin.rawValue)
        }
        anchor = corrected
        isPlaying = nextPlaying
        rate = nextRate
        sampledAt = ProcessInfo.processInfo.systemUptime
        lastSampleOrigin = origin
        transportSuspended = false
        tick()
    }

    func adjustOffset(by delta: Double) {
        offset = min(10, max(-10, ((offset + delta) * 10).rounded() / 10))
    }

    func estimatedProgress() -> Double {
        let elapsed = rawProgress()
        let duration = currentSong?.duration ?? 0
        return max(0, min(elapsed + offset + defaultAdvance, duration > 0 ? duration : .greatestFiniteMagnitude))
    }

    func playbackPosition() -> Double {
        let duration = currentSong?.duration ?? 0
        return max(0, min(rawProgress(), duration > 0 ? duration : .greatestFiniteMagnitude))
    }

    private func rawProgress() -> Double {
        anchor + (isPlaying ? (ProcessInfo.processInfo.systemUptime - sampledAt) * rate : 0)
    }

    func suspend() {
        anchor = rawProgress()
        sampledAt = ProcessInfo.processInfo.systemUptime
        isPlaying = false
        transportSuspended = true
        tick()
    }
    func tick() {
        let next = estimatedProgress()
        if progress != next { progress = next }
    }
    func clear() {
        currentSong = nil; isPlaying = false; anchor = 0; progress = 0
        loadingOffset = true; offset = 0; loadingOffset = false
        lastTimestamp = nil; lastElapsed = nil; timestampAdjustment = 0
        inheritedTimestamp = nil; transportSuspended = false; lastCorrection = 0
    }
    func simulateDriftForTesting(_ seconds: Double) { anchor += seconds; tick() }
}

/// Supervises the event stream and independently checks state at low frequency.
@MainActor final class PlaybackBridge {
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var probe: Process?
    private var generation = UUID()
    private var wanted = false
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var healthTimer: Timer?
    private var observers = [NSObjectProtocol]()
    private var streamBegan = Date()
    private var streamRevision = 0
    private var lastProbeAt = -Double.infinity
    private var observedPlaying = false
    private var observedTitle: String?
    private var confirmations = [DispatchWorkItem]()
    var onSnapshot: ((RemoteSnapshot?, PlaybackSampleOrigin) -> Void)?
    var onError: ((String) -> Void)?

    static func retryDelay(_ failures: Int) -> Double {
        min(15, pow(2, Double(max(0, min(failures - 1, 4)))))
    }

    private func arguments(_ command: String) -> [String]? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        var args = [script.path, framework.path, command, "--no-artwork", "--micros"]
        if command == "stream" { args += ["--no-diff", "--debounce=50"] }
        return args
    }

    func start() {
        stop()
        wanted = true
        failures = 0
        connect()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        timer.tolerance = 0.15
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        checkHealth(force: true)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.start() }
        })
    }

    private func connect() {
        guard wanted else { return }
        retry = nil
        guard let args = arguments("stream") else {
            onError?("播放信息组件缺失，请重新安装软件")
            return
        }
        let task = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        output = pipe
        errors = errorPipe
        generation = UUID()
        let token = generation
        streamBegan = Date()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = errorPipe
        let errorLog = BoundedProcessOutput()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { errorLog.append(data) }
        }
        let parser = SnapshotLineReader { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.wanted, self.generation == token else { return }
                if Date().timeIntervalSince(self.streamBegan) > 10 { self.failures = 0 }
                self.streamRevision += 1
                let changed = snapshot?.playing != nil && snapshot?.playing != self.observedPlaying
                    || snapshot?.title != nil && snapshot?.title != self.observedTitle
                if let playing = snapshot?.playing { self.observedPlaying = playing }
                if let title = snapshot?.title { self.observedTitle = title }
                self.onSnapshot?(snapshot, .stream)
                if changed { self.confirmTimeline() }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { parser.append(data) }
        }
        task.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let reason = "exit=\(task.terminationStatus), reason=\(task.terminationReason.rawValue), \(errorLog.text())"
            Task { @MainActor in
                guard let self, self.wanted, self.generation == token else { return }
                self.process = nil
                self.scheduleRetry(reason)
            }
        }
        do { try task.run(); process = task }
        catch { scheduleRetry(error.localizedDescription) }
    }

    private func scheduleRetry(_ reason: String) {
        guard wanted, retry == nil else { return }
        failures += 1
        let delay = Self.retryDelay(failures)
        NSLog("Flowflow transport interrupted; retry in %.0fs: %@", delay, reason)
        onError?("播放连接中断，正在自动重连…")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func confirmTimeline() {
        confirmations.forEach { $0.cancel() }
        confirmations.removeAll()
        for delay in [0.25, 1.0] {
            let work = DispatchWorkItem { [weak self] in self?.checkHealth(force: true) }
            confirmations.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func checkHealth(force: Bool = false) {
        guard wanted else { return }
        if process?.isRunning != true, retry == nil { connect() }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = observedPlaying ? 2.0 : 6.0
        guard probe == nil, now - lastProbeAt >= 0.5, force || now - lastProbeAt >= interval,
              let args = arguments("get") else { return }
        lastProbeAt = now
        let revision = streamRevision
        let task = Process()
        let pipe = Pipe()
        let data = BoundedProcessOutput()
        let token = generation
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain final bytes even if process termination beats the read callback.
            data.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let bytes = data.bytes()
            Task { @MainActor in
                guard let self, self.wanted, self.probe === task else { return }
                self.probe = nil
                guard self.generation == token, self.streamRevision == revision, task.terminationStatus == 0 else { return }
                if let snapshot = try? JSONDecoder().decode(RemoteSnapshot.self, from: bytes) {
                    if let playing = snapshot.playing { self.observedPlaying = playing }
                    self.onSnapshot?(snapshot, .probe)
                } else if String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                    self.onSnapshot?(nil, .probe)
                }
            }
        }
        do {
            try task.run(); probe = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak task] in
                guard let self, let task, self.probe === task, task.isRunning else { return }
                self.probe = nil
                task.terminate()
            }
        } catch { probe = nil }
    }

    func stop() {
        wanted = false
        generation = UUID()
        retry?.cancel(); retry = nil
        confirmations.forEach { $0.cancel() }; confirmations.removeAll()
        lastProbeAt = -Double.infinity
        observedPlaying = false; observedTitle = nil
        healthTimer?.invalidate(); healthTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        if let probe, probe.isRunning { probe.terminate() }
        process = nil; probe = nil; output = nil; errors = nil
    }

    func simulateFailureForTesting() { process?.terminate() }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        if data.count > 65536 { data.removeFirst(data.count - 65536) }
    }
    func bytes() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    func text() -> String { String(data: bytes(), encoding: .utf8) ?? "" }
}

private final class SnapshotLineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    let receive: @Sendable (RemoteSnapshot?) -> Void
    init(receive: @escaping @Sendable (RemoteSnapshot?) -> Void) { self.receive = receive }
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            if line == Data("null".utf8) { receive(nil) }
            else if let event = try? JSONDecoder().decode(RemoteEvent.self, from: line), event.type == "data" {
                receive(event.payload)
            }
        }
        if buffer.count > 1_048_576 { buffer.removeAll() }
    }
}
