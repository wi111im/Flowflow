import Foundation
import JavaScriptCore
import zlib

/// Only decodes lyric payloads; never used for audio, account or credential data.
enum QRCDecoder {
    static func decode(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 262144 else { throw LyricsFailure.noLyrics }
        if value.hasPrefix("<") || value.hasPrefix("[") { return value }
        var encrypted = value
        if value.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) == nil {
            guard let decoded = Data(base64Encoded: value) else { throw LyricsFailure.badResponse }
            if let text = String(data: decoded, encoding: .utf8), text.hasPrefix("<") || text.hasPrefix("[") { return text }
            encrypted = decoded.map { String(format: "%02x", $0) }.joined()
        }
        guard encrypted.count % 16 == 0,
              let scriptURL = Bundle.main.url(forResource: "qrc-des", withExtension: "js"),
              let context = JSContext() else { throw LyricsFailure.badResponse }
        context.evaluateScript(try String(contentsOf: scriptURL, encoding: .utf8))
        guard context.exception == nil,
              let bytes = context.objectForKeyedSubscript("decodeQrcBytes")?.call(withArguments: [encrypted])?.toArray() as? [NSNumber],
              context.exception == nil, !bytes.isEmpty else { throw LyricsFailure.badResponse }
        let compressed = bytes.map { $0.uint8Value }
        var output = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
        var length = uLongf(output.count)
        let status = uncompress(&output, &length, compressed, uLong(compressed.count))
        guard status == Z_OK, let text = String(bytes: output.prefix(Int(length)), encoding: .utf8) else { throw LyricsFailure.badResponse }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\u{0000}"))
    }
}

enum QRCParser {
    private final class EntityReader: NSObject, XMLParserDelegate {
        var text = ""
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    }
    static func body(_ source: String) -> String {
        guard source.contains("LyricContent") else { return source }
        let expression = try! NSRegularExpression(pattern: #"LyricContent\s*=\s*(["'])([\s\S]*?)\1"#)
        let string = source as NSString
        guard let match = expression.firstMatch(in: source, range: NSRange(location: 0, length: string.length)) else { return "" }
        let encoded = string.substring(with: match.range(at: 2))
        // Parse as element text, preserving newlines in the original XML attribute.
        let reader = EntityReader()
        let parser = XMLParser(data: Data("<lyrics>\(encoded)</lyrics>".utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        return parser.parse() ? reader.text : ""
    }
    static func parse(_ source: String, translation: String = "") -> [LyricLine] {
        let text = body(source)
        let lineExpression = try! NSRegularExpression(pattern: #"^\[(-?\d+),(\d+)\](.*)$"#)
        let wordExpression = try! NSRegularExpression(pattern: #"(.*?)\((-?\d+),(\d+)\)"#)
        let offsetExpression = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#)
        let storage = text as NSString
        let offsetMatch = offsetExpression.firstMatch(in: text, range: NSRange(location: 0, length: storage.length))
        let offset = offsetMatch.flatMap { Double(storage.substring(with: $0.range(at: 1))) }.map { -$0 / 1000 } ?? 0
        var lines = [LyricLine]()
        for raw in text.components(separatedBy: .newlines) {
            let str = raw as NSString
            guard let line = lineExpression.firstMatch(in: raw, range: NSRange(location: 0, length: str.length)),
                  let start = Double(str.substring(with: line.range(at: 1))),
                  let duration = Double(str.substring(with: line.range(at: 2))) else { continue }
            let content = str.substring(with: line.range(at: 3)) as NSString
            let matches = wordExpression.matches(in: content as String, range: NSRange(location: 0, length: content.length))
            let syllables = matches.compactMap { match -> LyricSyllable? in
                let word = content.substring(with: match.range(at: 1))
                guard !word.isEmpty,
                      let wordStart = Double(content.substring(with: match.range(at: 2))),
                      let wordDuration = Double(content.substring(with: match.range(at: 3))) else { return nil }
                return LyricSyllable(text: word, startTime: wordStart / 1000 + offset,
                                     endTime: (wordStart + wordDuration) / 1000 + offset)
            }
            var lineText = syllables.isEmpty ? content as String : syllables.map(\.text).joined()
            if let last = matches.last, NSMaxRange(last.range) < content.length {
                lineText += content.substring(from: NSMaxRange(last.range))
            }
            guard !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // If an un-timed suffix exists, preserve the text without inventing word timings.
            let complete = syllables.map(\.text).joined() == lineText
            lines.append(LyricLine(time: max(0, start / 1000 + offset), duration: duration / 1000,
                                   text: lineText, syllables: complete ? syllables : []))
        }
        if lines.isEmpty { lines = LyricParser.parseLRC(text) }
        let translations = LyricParser.parseLRC(body(translation))
        return lines.sorted { $0.time < $1.time }.map { line in
            let translated = translations.min { abs($0.time - line.time) < abs($1.time - line.time) }
            guard let translated, abs(translated.time - line.time) <= 0.75 else { return line }
            return line.attachingTranslation(translated.text)
        }
    }
}

struct QQTrackCandidate: Sendable {
    let id: Int
    let mid: String
    let name: String
    let artists: [String]
    let album: String
    let duration: Double
    var versionTitle = ""

    func matchScore(for song: Song) -> Double? {
        guard LyricsQuality.songName(name) == LyricsQuality.songName(song.name),
              LyricsQuality.versionSignature(versionTitle.isEmpty ? name : versionTitle) == LyricsQuality.versionSignature(song.name),
              LyricsQuality.artistsMatch(artists, song.artist),
              duration > 0, song.duration > 0, abs(duration - song.duration) <= 3 else { return nil }
        let albumMatches = !album.isEmpty && LyricsQuality.identity(album) == LyricsQuality.identity(song.albumName)
        return (albumMatches ? 20 : 0) - abs(duration - song.duration)
    }
}

actor QQMusicLyricsService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    func loadCandidates(for song: Song) async throws -> [(LyricsResult, Double)] {
        var search = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        search.queryItems = [URLQueryItem(name: "key", value: "\(song.name) \(song.artist)"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8")]
        var searchJSON = [String: Any]()
        do { searchJSON = try await request(URLRequest(url: search.url!)) }
        catch { try Task.checkCancellation() }
        let data = searchJSON["data"] as? [String: Any] ?? [:]
        let songs = (data["song"] as? [String: Any])?["itemlist"] as? [[String: Any]] ?? []
        var seeds = [(Int, String)]()
        for item in songs.prefix(5) {
            guard let rawID = item["id"], let id = Int(String(describing: rawID)),
                  let title = item["name"] as? String,
                  LyricsQuality.songName(title) == LyricsQuality.songName(song.name),
                  let artist = item["singer"] as? String,
                  LyricsQuality.artistsMatch([artist], song.artist) else { continue }
            if !seeds.contains(where: { $0.0 == id }) { seeds.append((id, item["mid"] as? String ?? "")) }
        }
        if seeds.isEmpty {
            // The lyric catalogue can find songs omitted by the smartbox search.
            seeds = try await searchLyricCatalogue(song)
        }
        // Fetch catalogue details before any lyrics: never accept an unverified duration.
        guard !seeds.isEmpty else { return [] }
        var detailRequests = [String: Any]()
        for (index, seed) in seeds.enumerated() {
            detailRequests["detail\(index)"] = ["module": "music.pf_song_detail_svr", "method": "get_song_detail_yqq",
                "param": ["song_id": seed.0, "song_mid": seed.1]]
        }
        let details = try await musicu(detailRequests)
        var matched = [(QQTrackCandidate, Double)]()
        for (index, seed) in seeds.enumerated() {
            guard let root = details["detail\(index)"] as? [String: Any], (root["code"] as? Int) == 0,
                  let values = root["data"] as? [String: Any], let track = values["track_info"] as? [String: Any],
                  let name = (track["name"] ?? track["title"]) as? String else { continue }
            let candidate = QQTrackCandidate(id: seed.0, mid: seed.1, name: name,
                artists: (track["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                album: (track["album"] as? [String: Any])?["name"] as? String ?? "",
                duration: (track["interval"] as? NSNumber)?.doubleValue ?? 0,
                versionTitle: [track["title"] as? String ?? "", track["subtitle"] as? String ?? ""].joined(separator: " "))
            if let score = candidate.matchScore(for: song) { matched.append((candidate, score)) }
        }
        let selected = Array(matched.sorted { $0.1 > $1.1 }.prefix(3))
        guard !selected.isEmpty else { return [] }
        var requests = [String: Any]()
        for (index, pair) in selected.enumerated() {
            requests["lyric\(index)"] = ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                "param": ["songID": pair.0.id, "crypt": 1, "qrc": 1, "qrc_t": 0, "lrc_t": 0,
                          "trans": 1, "trans_t": 0, "roma": 0, "roma_t": 0, "type": -1, "ct": 19, "cv": 1873]]
        }
        let payload = try await musicu(requests)
        var results = [(LyricsResult, Double)]()
        for (index, pair) in selected.enumerated() {
            try Task.checkCancellation()
            guard let root = payload["lyric\(index)"] as? [String: Any], (root["code"] as? Int) == 0,
                  let data = root["data"] as? [String: Any], let encoded = data["lyric"] as? String,
                  let decoded = try? QRCDecoder.decode(encoded) else { continue }
            let translated = (data["trans"] as? String).flatMap { try? QRCDecoder.decode($0) } ?? ""
            let lines = QRCParser.parse(decoded, translation: translated)
            if !lines.isEmpty {
                let pure = lines.contains { LyricsQuality.isInstrumentalText($0.text) }
                    && !lines.contains(where: LyricsQuality.isContent)
                results.append((LyricsResult(lines: pure ? [] : lines, pureMusic: pure, songID: String(pair.0.id), source: .qq,
                    selectionReason: "QQ 音乐候选"), pair.1))
            }
        }
        return results
    }

    private func searchLyricCatalogue(_ song: Song) async throws -> [(Int, String)] {
        var url = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_search_pc_lrc.fcg")!
        url.queryItems = [URLQueryItem(name: "SONGNAME", value: song.name), URLQueryItem(name: "SINGERNAME", value: song.artist),
            URLQueryItem(name: "TYPE", value: "2"), URLQueryItem(name: "RANGE_MIN", value: "1"), URLQueryItem(name: "RANGE_MAX", value: "5")]
        var req = URLRequest(url: url.url!)
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 512000,
              let xml = String(data: data, encoding: .utf8) else { throw LyricsFailure.badResponse }
        let expression = try! NSRegularExpression(pattern: #"<songinfo\s+id="(\d+)"[^>]*>([\s\S]*?)</songinfo>"#)
        let storage = xml as NSString
        var results = [(Int, String)]()
        for match in expression.matches(in: xml, range: NSRange(location: 0, length: storage.length)).prefix(5) {
            let body = storage.substring(with: match.range(at: 2)) as NSString
            func field(_ name: String) -> String {
                let regex = try! NSRegularExpression(pattern: "<" + name + #">\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*</"# + name + ">")
                guard let found = regex.firstMatch(in: body as String, range: NSRange(location: 0, length: body.length)) else { return "" }
                let encoded = body.substring(with: found.range(at: 1))
                return encoded.removingPercentEncoding ?? encoded
            }
            guard let id = Int(storage.substring(with: match.range(at: 1))),
                  LyricsQuality.songName(field("name")) == LyricsQuality.songName(song.name),
                  LyricsQuality.artistsMatch([field("singername")], song.artist),
                  !results.contains(where: { $0.0 == id }) else { continue }
            results.append((id, ""))
        }
        return results
    }

    private func musicu(_ modules: [String: Any]) async throws -> [String: Any] {
        var body = modules
        body["comm"] = ["ct": "19", "cv": "1873", "uin": "0", "tmeAppID": "qqmusic", "tmeLoginType": 2] as [String: Any]
        var req = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await request(req)
    }

    private func request(_ input: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        var req = input
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], (json["code"] as? Int) == 0 else { throw LyricsFailure.badResponse }
        return json
    }
}
