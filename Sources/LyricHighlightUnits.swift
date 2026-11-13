import Foundation

struct LyricHighlightUnit: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Preserve authored time ranges, merging Latin fragments into complete words.
/// Chinese characters remain separate; no letter-by-letter timing is invented.
enum LyricHighlightUnits {
    static func make(for line: LyricLine) -> [LyricHighlightUnit] {
        guard !line.syllables.isEmpty,
              line.syllables.map(\.text).joined() == line.text else { return [] }
        let timed = line.syllables.flatMap { syllable in
            syllable.text.map { (character: $0, start: syllable.startTime, end: syllable.endTime) }
        }
        var units = [LyricHighlightUnit]()
        var index = 0
        while index < timed.count {
            let first = timed[index]
            var endIndex = index + 1
            if isWordCharacter(first.character) {
                while endIndex < timed.count {
                    let char = timed[endIndex].character
                    if isWordCharacter(char) { endIndex += 1 }
                    else if ["'", "’", "-"].contains(String(char)), endIndex + 1 < timed.count,
                            isWordCharacter(timed[endIndex + 1].character) { endIndex += 1 }
                    else { break }
                }
            }
            let group = timed[index..<endIndex]
            units.append(LyricHighlightUnit(text: String(group.map(\.character)),
                start: group.map(\.start).min()!, end: group.map(\.end).max()!))
            index = endIndex
        }
        return units
    }

    // Split untimed lines for visual motion only; every unit keeps the same
    // line timestamp, so no artificial word-singing timings are introduced.
    static func untimedMotionUnits(_ text: String) -> [String] {
        let characters = Array(text)
        var units = [String]()
        var index = 0
        while index < characters.count {
            var end = index + 1
            if isWordCharacter(characters[index]) {
                while end < characters.count {
                    let char = characters[end]
                    if isWordCharacter(char) { end += 1 }
                    else if ["'", "’", "-"].contains(String(char)), end + 1 < characters.count,
                            isWordCharacter(characters[end + 1]) { end += 1 }
                    else { break }
                }
            }
            units.append(String(characters[index..<end]))
            index = end
        }
        return units
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        let isHan = character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
            default: return false
            }
        }
        return !isHan && character.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
}
