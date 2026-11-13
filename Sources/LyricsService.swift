import Foundation
import SQLite3

struct TrackCandidate: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let artists: [String]
    let album: String
    /// NetEase search payloads use milliseconds.
    let duration: Double

    var artistText: String { artists.joined(separator: " / ") }
    var durationSeconds: Double { duration > 10_000 ? duration / 1000 : duration }
    var durationText: String {
        let value = max(0, Int(durationSeconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    init?(_ json: [String: Any]) {
        guard let name = json["name"] as? String, let rawID = json["id"] else { return nil }
        self.id = String(describing: rawID)
        self.name = name
        self.artists = ((json["artists"] ?? json["ar"]) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        self.album = ((json["album"] ?? json["al"]) as? [String: Any])?["name"] as? String ?? ""
        self.duration = ((json["duration"] ?? json["dt"]) as? NSNumber)?.doubleValue ?? 0
    }

    func score(for song: Song) -> Double? {
        func normalized(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        guard normalized(name) == normalized(song.name), !artists.isEmpty,
              artists.contains(where: { normalized(song.artist).contains(normalized($0)) }) else { return nil }
        let difference = abs(durationSeconds - song.duration)
        guard song.duration == 0 || duration == 0 || difference < 4 else { return nil }
        return (normalized(album) == normalized(song.albumName) ? 20 : 0) - difference
    }
}

enum LyricsFailure: LocalizedError {
    case unmatched, noLyrics, badResponse
    var errorDescription: String? {
        switch self {
        case .unmatched: "未匹配到这首歌的歌词"
        case .noLyrics: "这首歌暂时没有可用歌词"
        case .badResponse: "歌词服务暂不可用，请稍后重试"
        }
    }
}

enum LyricsSource: String, Sendable { case netease = "网易云", qq = "QQ 音乐" }
struct LyricsResult: Sendable {
    let lines: [LyricLine]
    let pureMusic: Bool
    let songID: String
    var source: LyricsSource = .netease
    var selectionReason = ""
    var displayStatus: String {
        if pureMusic { return "纯音乐" }
        let kind = lines.contains { !$0.syllables.isEmpty } ? "逐字歌词" : "整句歌词"
        return "\(source.rawValue) · \(kind)已同步"
    }
}

actor LyricsService {
    private var cached = [String: LyricsResult]()
    private let qqService = QQMusicLyricsService()
    private let matchStore = LyricMatchStore()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    func load(_ song: Song, refresh: Bool = false,
              onInitial: (@MainActor @Sendable (LyricsResult) -> Void)? = nil) async throws -> LyricsResult {
        if !refresh, let result = cached[song.id] { return result }
        let manual = matchStore.load(for: song)
        let qqSong: Song
        if let manual {
            qqSong = Song(id: song.id, name: manual.name, artist: manual.artist,
                          albumName: manual.album.isEmpty ? song.albumName : manual.album,
                          duration: song.duration > 0 ? song.duration : manual.duration)
        } else {
            qqSong = song
        }
        var original: LyricsResult?
        var originalError: Error = LyricsFailure.noLyrics
        do {
            if let manual {
                var loaded = try await loadNetEaseTrack(id: manual.songID)
                loaded.selectionReason = "已使用手动匹配的网易云歌词"
                original = loaded
            } else {
                original = try await loadNetEase(song)
            }
            if let original { await onInitial?(original) }
        } catch {
            try Task.checkCancellation()
            originalError = error
        }
        try Task.checkCancellation()
        var selected = original
        var qqUnavailable = false
        do {
            let candidates = try await qqService.loadCandidates(for: qqSong)
            for (candidate, _) in candidates {
                try Task.checkCancellation()
                let compatible: [LyricLine]
                if let original, !original.lines.isEmpty {
                    guard let aligned = LyricsQuality.aligned(candidate.lines, to: original.lines) else { continue }
                    compatible = aligned
                } else { compatible = candidate.lines }
                let reason = candidate.pureMusic ? "QQ 音乐标记为纯音乐，显示等待圆点"
                    : (compatible.contains { !$0.syllables.isEmpty }
                        ? "歌曲版本与时长匹配，逐字时间轴更完整"
                        : "网易云无可用歌词，已选用匹配的 QQ 歌词")
                let alternative = LyricsResult(lines: compatible, pureMusic: candidate.pureMusic, songID: candidate.songID,
                    source: .qq, selectionReason: reason)
                if LyricsQuality.prefer(alternative, over: selected, duration: song.duration) { selected = alternative }
            }
        } catch {
            try Task.checkCancellation()
            qqUnavailable = true
        }
        try Task.checkCancellation()
        guard var result = selected else { throw originalError }
        if result.source == .netease {
            if manual != nil {
                result.selectionReason = qqUnavailable
                    ? "手动匹配网易云歌词；QQ 音乐暂不可用"
                    : "手动匹配网易云歌词；未发现更优的 QQ 歌词"
            } else {
                result.selectionReason = qqUnavailable ? "QQ 音乐暂不可用，保留网易云歌词" : "未发现匹配且更优的 QQ 歌词，保留网易云"
            }
        }
        if cached.count >= 80 { cached.removeAll(keepingCapacity: true) }
        cached[song.id] = result
        return result
    }

    func search(_ query: String) async throws -> [TrackCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var url = URLComponents(string: "https://music.163.com/api/search/get")!
        url.queryItems = [URLQueryItem(name: "s", value: trimmed),
                          URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "20")]
        let json = try await request(url.url!)
        let result = json["result"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        return (result["songs"] as? [[String: Any]] ?? []).compactMap(TrackCandidate.init).filter {
            seen.insert($0.id).inserted
        }
    }

    func remember(_ candidate: TrackCandidate, for song: Song) {
        matchStore.save(.netease(candidate), for: song)
        cached.removeValue(forKey: song.id)
    }

    func forgetMatch(for song: Song) {
        matchStore.clear(for: song)
        cached.removeValue(forKey: song.id)
    }

    func manualMatch(for song: Song) -> ManualLyricMatch? {
        matchStore.load(for: song)
    }

    private func loadNetEase(_ song: Song) async throws -> LyricsResult {
        var candidates = localCandidates(named: song.name)
        if !candidates.contains(where: { $0.score(for: song) != nil }) {
            candidates += try await search("\(song.name) \(song.artist)")
        }
        try Task.checkCancellation()
        guard let track = candidates.compactMap({ candidate -> (TrackCandidate, Double)? in
            candidate.score(for: song).map { (candidate, $0) }
        }).max(by: { $0.1 < $1.1 })?.0 else { throw LyricsFailure.unmatched }
        return try await loadNetEaseTrack(id: track.id)
    }

    private func loadNetEaseTrack(id: String) async throws -> LyricsResult {
        // Prefer real YRC timings, retaining the old endpoint as a fallback.
        var url = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
        url.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "cp", value: "false")]
            + ["lv", "kv", "tv", "rv", "yv", "ytv", "yrv"].map { URLQueryItem(name: $0, value: "0") }
        var json: [String: Any]
        do { json = try await request(url.url!) }
        catch {
            try Task.checkCancellation()
            json = [:]
        }
        func source(_ key: String) -> String { (json[key] as? [String: Any])?["lyric"] as? String ?? "" }
        if source("yrc").isEmpty && source("lrc").isEmpty {
            url = URLComponents(string: "https://music.163.com/api/song/lyric")!
            url.queryItems = [URLQueryItem(name: "id", value: id)]
                + ["lv", "kv", "tv", "rv"].map { URLQueryItem(name: $0, value: "-1") }
            json = try await request(url.url!)
        }
        let pure = (json["pureMusic"] as? Bool == true) || (json["nolyric"] as? Bool == true)
        let lines = LyricParser.parse(yrc: source("yrc"), lrc: source("lrc"),
                                     translatedYRC: source("ytlrc"), translatedLRC: source("tlyric"),
                                     romanizedYRC: source("yromalrc"), romanizedLRC: source("romalrc"))
        guard pure || !lines.isEmpty else { throw LyricsFailure.noLyrics }
        return LyricsResult(lines: lines, pureMusic: pure, songID: id)
    }

    private func request(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int ?? 200) == 200 else { throw LyricsFailure.badResponse }
        return json
    }

    // Read only the song catalogue. Never reads cookies, login data or settings.
    private func localCandidates(named title: String) -> [TrackCandidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relative = ["Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3",
                        "Library/Containers/com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3"]
        for path in relative {
            var db: OpaquePointer?
            guard sqlite3_open_v2(home.appendingPathComponent(path).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db); continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 150)
            var results = [TrackCandidate]()
            for table in ["historyTracks", "dbTrack"] {
                var statement: OpaquePointer?
                let query = "SELECT jsonStr FROM \(table) WHERE json_extract(jsonStr,'$.name') = ? LIMIT 30"
                guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(statement) }
                _ = title.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(statement, 0) else { continue }
                    let data = Data(String(cString: raw).utf8)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidate = TrackCandidate(json) { results.append(candidate) }
                }
            }
            if !results.isEmpty { return results }
        }
        return []
    }
}
