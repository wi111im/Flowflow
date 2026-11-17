import Foundation
import NaturalLanguage

struct LyricHighlightUnit: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Preserve authored time ranges, merging Latin fragments into complete words.
/// Chinese characters remain separate; no letter-by-letter timing is invented.
enum LyricHighlightUnits {
    static func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3041...0x3096, 0x30A1...0x30FA, 0xFF66...0xFF9D: return true
            default: return false
            }
        }
    }

    static func make(for line: LyricLine, japanese: Bool = false, fallbackEnd: TimeInterval? = nil, estimate: Bool = false) -> [LyricHighlightUnit] {
        guard !line.syllables.isEmpty, line.syllables.map(\.text).joined() == line.text else {
            return estimate ? estimatedUnits(for: line, end: fallbackEnd, japanese: japanese || containsJapaneseKana(line.text)) : []
        }
        if japanese || containsJapaneseKana(line.text) {
            return line.syllables.flatMap { syllable -> [LyricHighlightUnit] in
                let characters = Array(syllable.text)
                guard !characters.isEmpty else { return [] }
                let duration = syllable.endTime - syllable.startTime
                let step = duration.isFinite && duration > 0 ? duration / Double(characters.count) : 0
                return characters.enumerated().map { index, character in
                    let start = syllable.startTime + Double(index) * step
                    let end = step > 0 && index == characters.count - 1 ? syllable.endTime : start + step
                    return LyricHighlightUnit(text: String(character), start: start, end: end)
                }
            }
        }
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

    // Distribute the available line time across words or characters.
    // Spaces and punctuation follow adjacent units without taking a time slot.
    private static func estimatedUnits(for line: LyricLine, end: TimeInterval?, japanese: Bool) -> [LyricHighlightUnit] {
        guard line.time.isFinite else { return [] }
        guard let end, end.isFinite, end > line.time else { return [] }
        let parts = japanese ? line.text.map(String.init) : estimatedTextUnits(line.text)
        let meaningful = parts.map { part in
            part.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        }
        let count = meaningful.filter { $0 }.count
        guard count > 0 else { return [] }
        let step = (end - line.time) / Double(count)
        var position = 0
        return parts.enumerated().map { index, text in
            if meaningful[index] {
                let start = line.time + Double(position) * step
                position += 1
                let finish = position == count ? end : line.time + Double(position) * step
                return LyricHighlightUnit(text: text, start: start, end: finish)
            }
            let time = line.time + Double(position) * step
            return LyricHighlightUnit(text: text, start: time, end: time)
        }
    }

    private static func estimatedTextUnits(_ text: String) -> [String] {
        // Languages such as Thai do not consistently separate words with spaces.
        let needsWordSegmentation = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF: return true
            default: return false
            }
        }
        guard needsWordSegmentation else { return untimedMotionUnits(text) }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var parts = [String]()
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if cursor < range.lowerBound { parts.append(contentsOf: text[cursor..<range.lowerBound].map(String.init)) }
            parts.append(String(text[range]))
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { parts.append(contentsOf: text[cursor...].map(String.init)) }
        return parts
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
