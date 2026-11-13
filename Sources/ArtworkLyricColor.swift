import AppKit
import Foundation

enum ArtworkLyricColor {
    static func load(for song: Song) async -> (Double, Double, Double)? {
        guard let data = await loadArtwork(for: song), let image = NSImage(data: data) else { return nil }
        return dominantColor(image)
    }

    static func loadArtwork(for song: Song) async -> Data? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework").path
        return await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script, framework, "get", "--micros"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  SupportedPlayers.contains(json["bundleIdentifier"] as? String),
                  json["title"] as? String == song.name,
                  json["artist"] as? String == song.artist,
                  let encoded = json["artworkData"] as? String,
                  let bytes = Data(base64Encoded: encoded) else { return nil }
            return bytes
        }.value
    }

    static func dominantColor(_ image: NSImage) -> (Double, Double, Double)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let color = representativeColor(pixels) else { return nil }
        return makeVisible(color)
    }

    // Preserve hue while lifting weak saturation and dark colors. Neutral
    // covers have no hue to amplify, so lift their brightness only.
    static func makeVisible(_ color: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = color
        let high = max(r, g, b), low = min(r, g, b)
        let chroma = high - low
        let value = max(high, 0.90)
        guard chroma > 0.001, high > 0 else { return (value, value, value) }
        let originalSaturation = chroma / high
        let saturation = max(originalSaturation, 0.80)
        let floor = value * (1 - saturation)
        let range = value * saturation
        func adjust(_ component: Double) -> Double { floor + (component - low) / chroma * range }
        return (adjust(r), adjust(g), adjust(b))
    }

    private struct ColorGroup {
        var count = 0
        var red = 0.0, green = 0.0, blue = 0.0, saturation = 0.0
        mutating func add(_ other: ColorGroup) {
            count += other.count; red += other.red; green += other.green
            blue += other.blue; saturation += other.saturation
        }
    }

    // Adjacent hue, saturation and brightness bands form a tolerant color group.
    // Transparent pixels count toward the full image area, but cannot supply a color.
    static func representativeColor(_ pixels: [UInt8]) -> (Double, Double, Double)? {
        let total = pixels.count / 4
        guard total > 0 else { return nil }
        let bands = 8
        func index(_ hue: Int, _ saturation: Int, _ value: Int) -> Int {
            (hue * bands + saturation) * bands + value
        }
        var groups = Array(repeating: ColorGroup(), count: 36 * bands * bands)
        var neutrals = Array(repeating: ColorGroup(), count: bands)
        for i in stride(from: 0, to: total * 4, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 200.0 / 255 else { continue }
            let r = min(1, Double(pixels[i]) / 255 / alpha)
            let g = min(1, Double(pixels[i + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[i + 2]) / 255 / alpha)
            let high = max(r, g, b), low = min(r, g, b), chroma = high - low
            let saturation = high > 0 ? chroma / high : 0
            var pixel = ColorGroup()
            pixel.count = 1; pixel.red = r; pixel.green = g; pixel.blue = b; pixel.saturation = saturation
            let valueBand = min(bands - 1, Int(high * Double(bands)))
            guard saturation >= 0.15, chroma > 0 else { neutrals[valueBand].add(pixel); continue }
            var hue: Double
            if high == r { hue = (g - b) / chroma }
            else if high == g { hue = (b - r) / chroma + 2 }
            else { hue = (r - g) / chroma + 4 }
            hue = hue.truncatingRemainder(dividingBy: 6)
            if hue < 0 { hue += 6 }
            let h = min(35, Int(hue * 6))
            let satBand = min(bands - 1, Int(saturation * Double(bands)))
            groups[index(h, satBand, valueBand)].add(pixel)
        }
        let neutralCount = neutrals.reduce(0) { $0 + $1.count }
        let minimalCover = neutralCount * 10 >= total * 9
        var best: ColorGroup?
        var chosenAccent: (h: Int, s: Int, v: Int)?
        func consider(_ group: ColorGroup, accent: (h: Int, s: Int, v: Int)? = nil) {
            let eligible = group.count * 20 >= total
            let sparseAccent = minimalCover && accent != nil && group.count * 200 >= total
                && group.count > 0 && group.saturation / Double(group.count) >= 0.65
            guard eligible || sparseAccent else { return }
            guard let current = best else { best = group; chosenAccent = sparseAccent ? accent : nil; return }
            let score = group.saturation / Double(group.count)
            let previous = current.saturation / Double(current.count)
            if score > previous + 0.000001 || (abs(score - previous) <= 0.000001 && group.count > current.count) {
                best = group
                chosenAccent = sparseAccent ? accent : nil
            }
        }
        for v in 0..<bands {
            var group = ColorGroup()
            for value in max(0, v-1)...min(bands-1, v+1) { group.add(neutrals[value]) }
            consider(group)
        }
        for h in 0..<36 {
            for saturation in 0..<bands {
                for value in 0..<bands {
                    var group = ColorGroup()
                    for dh in -1...1 {
                        for ds in max(0, saturation-1)...min(bands-1, saturation+1) {
                            for dv in max(0, value-1)...min(bands-1, value+1) {
                                group.add(groups[index((h + dh + 36) % 36, ds, dv)])
                            }
                        }
                    }
                    consider(group, accent: (h, saturation, value))
                }
            }
        }
        guard let best else { return nil }
        if let accent = chosenAccent {
            // Prefer the most frequent actual pixel in the winning accent group.
            // This avoids washing out flat artwork with antialiased edge colors.
            var frequencies: [UInt32: Int] = [:]
            for i in stride(from: 0, to: total * 4, by: 4) {
                let alpha = Double(pixels[i + 3]) / 255
                guard alpha > 200.0 / 255 else { continue }
                let r = min(1, Double(pixels[i]) / 255 / alpha)
                let g = min(1, Double(pixels[i + 1]) / 255 / alpha)
                let b = min(1, Double(pixels[i + 2]) / 255 / alpha)
                let high = max(r, g, b), low = min(r, g, b), chroma = high - low
                guard high > 0, chroma / high >= 0.15 else { continue }
                var hue: Double
                if high == r { hue = (g - b) / chroma }
                else if high == g { hue = (b - r) / chroma + 2 }
                else { hue = (r - g) / chroma + 4 }
                hue = hue.truncatingRemainder(dividingBy: 6)
                if hue < 0 { hue += 6 }
                let h = min(35, Int(hue * 6))
                let sb = min(bands - 1, Int(chroma / high * Double(bands)))
                let vb = min(bands - 1, Int(high * Double(bands)))
                let distance = min((h - accent.h + 36) % 36, (accent.h - h + 36) % 36)
                guard distance <= 1, abs(sb - accent.s) <= 1, abs(vb - accent.v) <= 1 else { continue }
                let ri = UInt32((r * 255).rounded()), gi = UInt32((g * 255).rounded()), bi = UInt32((b * 255).rounded())
                let key = (ri << 16) | (gi << 8) | bi
                if frequencies[key] != nil || frequencies.count < 65536 { frequencies[key, default: 0] += 1 }
            }
            if let key = frequencies.max(by: { $0.value < $1.value })?.key {
                return (Double((key >> 16) & 255) / 255, Double((key >> 8) & 255) / 255, Double(key & 255) / 255)
            }
        }
        let count = Double(best.count)
        return (best.red / count, best.green / count, best.blue / count)
    }
}
