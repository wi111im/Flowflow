import AppKit
import SwiftUI

enum LyricsFontFamily {
    static func installedFamilies() -> [String] {
        Array(Set(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func font(_ family: String, size: CGFloat, weight: Font.Weight) -> Font {
        family.isEmpty ? .system(size: size, weight: weight) : .custom(family, size: size).weight(weight)
    }

    static func displayName(_ family: String) -> String {
        NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }
}
