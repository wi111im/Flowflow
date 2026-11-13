import Foundation

enum SupportedPlayers {
    static let identifiers: Set<String> = ["com.netease.163music", "com.tencent.QQMusicMac", "com.apple.Music"]
    static func contains(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifiers.contains(identifier)
    }
}
