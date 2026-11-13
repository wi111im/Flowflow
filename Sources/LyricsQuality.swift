import Foundation

struct LyricsQualityReport: Sendable {
    let timedCoverage: Double
    let granularity: Double
    let score: Double
    let usable: Bool
}

enum LyricsQuality {
    static func identity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
    static func songName(_ text: String) -> String {
        // Promotional soundtrack annotations do not identify a different recording.
        let stripped = text.replacingOccurrences(of: #"\s*[（(]From\b[^）)]*[)）]\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return identity(stripped)
    }
    static func versionSignature(_ text: String) -> Set<String> {
        let pattern = #"\b(live|acoustic|remix|instrumental|karaoke|sped\s*up|slowed|remaster(?:ed)?|cover|explicit|clean|radio\s*edit)\b|现场|伴奏|翻唱|重制|加速|慢速|重混"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let storage = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: storage.length)).map {
            identity(storage.substring(with: $0.range))
        })
    }
    static func artistsMatch(_ names: [String], _ target: String) -> Bool {
        func parts(_ value: String) -> Set<String> {
            var text = value.lowercased()
            for separator in [" feat. ", " ft. ", " featuring ", "/", "、", "&", ",", "，", ";", "；"] {
                text = text.replacingOccurrences(of: separator, with: "|")
            }
            return Set(text.split(separator: "|").map { identity(String($0)) }.filter { !$0.isEmpty })
        }
        let artists = names.reduce(into: Set<String>()) { $0.formUnion(parts($1)) }
        let expected = parts(target)
        return !artists.isEmpty && artists == expected
    }
    static func normalizedText(_ value: String) -> String {
        identity(value).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func isInstrumentalText(_ text: String) -> Bool {
        ["纯音乐", "纯音乐请欣赏", "纯音乐敬请欣赏", "此歌曲为没有填词的纯音乐请您欣赏",
         "此歌曲为没有填词的纯音乐请欣赏", "instrumental"].contains(normalizedText(text))
    }
    // Recognize production metadata by its role label, not by its position in a song.
    private static let creditRoles = #"作词|作詞|作曲|编曲|編曲|词曲作者|詞曲作者|词曲|詞曲|词作者|詞作者|曲作者|填词|填詞|制作人|製作人|制作|製作|监制|監製|出品人?|发行|發行|演唱|歌手|主唱|人声|人聲|和声|和聲|和音|混录师|混錄師|混录|混錄|混音|混音师|混音師|缩混|縮混|母带|母帶|录音|錄音|录制|錄製|吉他|贝斯|貝斯|鼓|键盘|鍵盤|钢琴|鋼琴|弦乐|弦樂|小提琴|大提琴|管弦乐|管弦樂|配唱|统筹|統籌|企划|企劃|策划|策劃|音频|音頻|工程师|工程師|录音棚|錄音棚|录音室|錄音室|工作室|音乐制作|音樂製作|制作协力|製作協力|版权|版權|词|詞|曲|lyrics?(?:\s+by)?|lyricist|music(?:\s+by)?|written\s+by|composed\s+by|composer|arrang(?:ed\s+by|er|ement)|produc(?:ed\s+by|er|tion)|mix(?:ed\s+by|ing|er)?|master(?:ed\s+by|ing)?|record(?:ed\s+by|ing)?|(?:recording|mixing|mastering)\s+engineer|engineer(?:ed\s+by)?|studio|vocals?|artist|guitar|bass|drums?|piano|keyboard|strings|publisher|copyright"#
    private static let creditExpression = try! NSRegularExpression(
        pattern: #"^\s*[\[【（(]?(?:"# + creditRoles + #")(?:\s*[/／&、+＋]\s*(?:"# + creditRoles + #"))*\s*(?:[\]】）)]\s*[:：﹕=＝-]?\s*|[:：﹕=＝—–-]\s*|\s+|$)\S*"#,
        options: [.caseInsensitive]
    )

    static func isCreditText(_ text: String) -> Bool {
        let cleaned = String(text.unicodeScalars.filter { ![0x200B, 0x200C, 0x200D, 0xFEFF].contains($0.value) })
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return creditExpression.firstMatch(in: cleaned, range: range) != nil
    }

    static func displayLines(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map { line in
            guard isCreditText(line.text) else { return line }
            return LyricLine(time: line.time, duration: line.duration, text: "...", agent: line.agent)
        }
    }
    static func isContent(_ line: LyricLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText(text).isEmpty else { return false }
        return !isCreditText(text) && !isInstrumentalText(text)
    }
    static func assess(_ lines: [LyricLine], duration: Double) -> LyricsQualityReport {
        let content = lines.filter(isContent)
        var total = 0, timed = 0, units = 0, uniqueTimings = 0, invalid = 0, checked = 0
        for line in content {
            total += normalizedText(line.text).count
            let highlights = LyricHighlightUnits.make(for: line).filter { !normalizedText($0.text).isEmpty }
            var previousStart = -Double.infinity
            var times = Set<String>()
            for unit in highlights {
                checked += 1
                let valid = unit.start.isFinite && unit.end.isFinite && unit.start >= -0.1
                    && unit.end > unit.start && unit.start >= line.time - 0.2
                    && unit.start + 0.05 >= previousStart
                    && (duration <= 0 || unit.end <= duration + 1.5)
                    && (line.duration == nil || unit.end <= line.time + (line.duration ?? 0) + 0.5)
                previousStart = unit.start
                if valid {
                    timed += normalizedText(unit.text).count
                    units += 1
                    times.insert("\(Int((unit.start * 1000).rounded()))|\(Int((unit.end * 1000).rounded()))")
                } else { invalid += 1 }
            }
            uniqueTimings += times.count
        }
        let coverage = total > 0 ? min(1, Double(timed) / Double(total)) : 0
        let granularity = units > 0 ? Double(uniqueTimings) / Double(units) : 0
        let badRatio = checked > 0 ? Double(invalid) / Double(checked) : 0
        let translated = content.isEmpty ? 0 : Double(content.filter(\.hasTranslation).count) / Double(content.count)
        let usable = total > 0 && badRatio <= 0.1 && content.allSatisfy { $0.time.isFinite && $0.time >= 0 }
        let score = coverage * 70 + granularity * 20 + translated * 5 + min(5, Double(content.count) / 6) - badRatio * 60
        return LyricsQualityReport(timedCoverage: coverage, granularity: granularity, score: score, usable: usable)
    }

    /// Reject different lyrics or unstable offsets; calibrate a small consistent offset
    /// against the original player's line timing before using a cross-provider source.
    static func aligned(_ candidate: [LyricLine], to original: [LyricLine]) -> [LyricLine]? {
        let reference = original.filter(isContent)
        let proposed = candidate.filter(isContent)
        guard !reference.isEmpty else { return candidate }
        let originalText = reference.map { normalizedText($0.text) }.joined()
        let candidateText = proposed.map { normalizedText($0.text) }.joined()
        guard !originalText.isEmpty, !candidateText.isEmpty else { return nil }
        func pairs(_ text: String) -> Set<String> {
            let chars = Array(text)
            if chars.count < 2 { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let a = pairs(originalText), b = pairs(candidateText)
        let similarity = Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
        let lengthRatio = Double(candidateText.count) / Double(originalText.count)
        guard similarity >= 0.72, (0.75...1.30).contains(lengthRatio) else { return nil }
        var differences = [Double]()
        for line in proposed {
            let key = normalizedText(line.text)
            guard key.count >= 3,
                  let match = reference.filter({ normalizedText($0.text) == key })
                    .min(by: { abs($0.time - line.time) < abs($1.time - line.time) }) else { continue }
            differences.append(line.time - match.time)
        }
        guard differences.count >= min(4, reference.count), !differences.isEmpty else { return nil }
        differences.sort()
        let offset = differences[differences.count / 2]
        let residuals = differences.map { abs($0 - offset) }.sorted()
        guard abs(offset) <= 2, residuals[Int(Double(residuals.count - 1) * 0.8)] <= 0.65,
              (residuals.last ?? 0) <= 1.25 else { return nil }
        return candidate.map { line in
            let delta = abs(offset) >= 0.06 ? -offset : 0
            let originalLine = reference.filter { normalizedText($0.text) == normalizedText(line.text) }
                .min { abs($0.time - (line.time + delta)) < abs($1.time - (line.time + delta)) }
            func shifted(_ syllables: [LyricSyllable]) -> [LyricSyllable] {
                syllables.map { LyricSyllable(text: $0.text, startTime: max(0, $0.startTime + delta), endTime: max(0, $0.endTime + delta)) }
            }
            return LyricLine(time: max(0, line.time + delta), duration: line.duration, text: line.text,
                syllables: shifted(line.syllables), romanization: line.romanization ?? originalLine?.romanization,
                romanizationSyllables: shifted(line.romanizationSyllables), translation: line.translation ?? originalLine?.translation,
                agent: line.agent, backgroundVocal: nil)
        }
    }

    static func prefer(_ candidate: LyricsResult, over current: LyricsResult?, duration: Double) -> Bool {
        if candidate.pureMusic {
            guard let current else { return true }
            return !current.pureMusic && current.lines.isEmpty
        }
        let proposed = assess(candidate.lines, duration: duration)
        guard proposed.usable else { return false }
        guard let current, !current.lines.isEmpty else { return true }
        let baseline = assess(current.lines, duration: duration)
        if !baseline.usable { return true }
        // Require a meaningful improvement; ties keep the original provider.
        return proposed.timedCoverage >= 0.65 && proposed.granularity >= 0.45
            && proposed.score > baseline.score + 5
    }
}
