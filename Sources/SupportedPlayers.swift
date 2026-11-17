import Foundation

enum SupportedPlayers {
    static let orderedIdentifiers = ["com.netease.163music", "com.tencent.QQMusicMac", "com.apple.Music"]
    static let identifiers = Set(orderedIdentifiers)
    static func contains(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifiers.contains(identifier)
    }
}

struct RecentPlayerStore {
    static let key = "playback.lastUsedApplication"
    let defaults: UserDefaults

    var lastUsed: String? {
        let id = defaults.string(forKey: Self.key)
        return SupportedPlayers.contains(id) ? id : nil
    }

    func record(_ snapshot: RemoteSnapshot) {
        guard snapshot.playing == true, let id = snapshot.bundleIdentifier,
              SupportedPlayers.contains(id),
              let title = snapshot.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lastUsed != id else { return }
        defaults.set(id, forKey: Self.key)
    }

    func candidates(running: Set<String>, available: Set<String>) -> [String] {
        let preferred = lastUsed.map { [$0] } ?? []
        let order = preferred + SupportedPlayers.orderedIdentifiers.filter { running.contains($0) }
            + SupportedPlayers.orderedIdentifiers
        var seen = Set<String>()
        return order.filter { available.contains($0) && seen.insert($0).inserted }
    }
}
