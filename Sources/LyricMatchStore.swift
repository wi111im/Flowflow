import Foundation

struct ManualLyricMatch: Codable, Equatable, Sendable {
    let source: String
    let songID: String
    let name: String
    let artist: String
    let album: String
    /// Duration in seconds.
    let duration: Double

    static func netease(_ candidate: TrackCandidate) -> ManualLyricMatch {
        ManualLyricMatch(source: LyricsSource.netease.rawValue,
                         songID: candidate.id,
                         name: candidate.name,
                         artist: candidate.artists.joined(separator: " / "),
                         album: candidate.album,
                         duration: candidate.duration > 10_000 ? candidate.duration / 1000 : candidate.duration)
    }
}

struct LyricMatchStore {
    static let key = "lyrics.manualMatches"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identity(for song: Song) -> String {
        let fields = [song.name, song.artist, song.albumName].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
    }

    func load(for song: Song) -> ManualLyricMatch? {
        guard let raw = defaults.dictionary(forKey: Self.key)?[identity(for: song)] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let match = try? JSONDecoder().decode(ManualLyricMatch.self, from: data),
              !match.songID.isEmpty else { return nil }
        return match
    }

    func save(_ match: ManualLyricMatch, for song: Song) {
        var stored = defaults.dictionary(forKey: Self.key) ?? [:]
        guard let data = try? JSONEncoder().encode(match),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        stored[identity(for: song)] = raw
        defaults.set(stored, forKey: Self.key)
    }

    func clear(for song: Song) {
        var stored = defaults.dictionary(forKey: Self.key) ?? [:]
        stored.removeValue(forKey: identity(for: song))
        if stored.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(stored, forKey: Self.key) }
    }
}
