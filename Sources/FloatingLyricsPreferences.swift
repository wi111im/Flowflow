import Foundation
import Observation

@MainActor
@Observable
final class FloatingLyricsPreferences {
    static let fontScaleRange = 0.5...2.0
    static let glowIntensityRange = 0.0...6.0
    static let glowRadiusRange = 2.0...30.0
    static let defaultGlowIntensity = 4.579151459854015
    static let defaultGlowRadius = 25.76665145985401
    static let textOpacityRange = 0.05...1.0
    static let lineSpacingRange = 2.0...18.0
    static let backgroundOpacityRange = 0.2...1.0
    static let backgroundBlurRange = 8.0...40.0
    static let cornerRadiusRange = 0.0...28.0

    static let defaultFontScale = 0.8041457572992701
    static let defaultTextAlignment = FloatingLyricsTextAlignment.center
    static let defaultFontWeight = LyricsFontWeight.bold
    static let defaultTextEffect = FloatingLyricsTextEffect.glow
    static let defaultTextOpacity = 1.0
    static let defaultLineSpacing = 2.0
    static let defaultBackgroundStyle = FloatingLyricsBackgroundStyle.transparent
    static let defaultBackgroundOpacity = 0.82
    static let defaultBackgroundBlur = 24.0
    static let defaultCornerRadius = 16.0

    private enum Key {
        static let showsTranslation = "floatingLyrics.showsTranslation"
        static let showsNextLine = "floatingLyrics.showsNextLine"
        static let dimCompletedLyrics = "floatingLyrics.dimCompletedLyrics"
        static let fontFamily = "floatingLyrics.fontFamily"
        static let fontScale = "floatingLyrics.fontScale"
        static let textAlignment = "floatingLyrics.textAlignment"
        static let fontWeight = "floatingLyrics.fontWeight"
        static let textEffect = "floatingLyrics.textEffect"
        static let glowIntensity = "floatingLyrics.glowIntensity"
        static let glowRadius = "floatingLyrics.glowRadius"
        static let textOpacity = "floatingLyrics.textOpacity"
        static let lineSpacing = "floatingLyrics.lineSpacing"
        static let backgroundStyle = "floatingLyrics.backgroundStyle"
        static let backgroundOpacity = "floatingLyrics.backgroundOpacity"
        static let backgroundBlur = "floatingLyrics.backgroundBlur"
        static let cornerRadius = "floatingLyrics.cornerRadius"
    }

    var showsTranslation: Bool {
        didSet {
            defaults.set(showsTranslation, forKey: Key.showsTranslation)
        }
    }

    var showsNextLine: Bool {
        didSet {
            defaults.set(showsNextLine, forKey: Key.showsNextLine)
        }
    }

    var dimCompletedLyrics: Bool {
        didSet { defaults.set(dimCompletedLyrics, forKey: Key.dimCompletedLyrics) }
    }

    var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    var fontScale: Double {
        didSet {
            defaults.set(fontScale, forKey: Key.fontScale)
        }
    }

    var textAlignment: FloatingLyricsTextAlignment {
        didSet {
            defaults.set(textAlignment.rawValue, forKey: Key.textAlignment)
        }
    }

    var fontWeight: LyricsFontWeight {
        didSet {
            defaults.set(fontWeight.rawValue, forKey: Key.fontWeight)
        }
    }

    var textEffect: FloatingLyricsTextEffect {
        didSet {
            defaults.set(textEffect.rawValue, forKey: Key.textEffect)
        }
    }

    var glowIntensity: Double {
        didSet { defaults.set(glowIntensity, forKey: Key.glowIntensity) }
    }

    var glowRadius: Double {
        didSet { defaults.set(glowRadius, forKey: Key.glowRadius) }
    }

    var textOpacity: Double {
        didSet {
            defaults.set(textOpacity, forKey: Key.textOpacity)
        }
    }

    var lineSpacing: Double {
        didSet {
            defaults.set(lineSpacing, forKey: Key.lineSpacing)
        }
    }

    var backgroundStyle: FloatingLyricsBackgroundStyle {
        didSet {
            defaults.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle)
        }
    }

    var backgroundOpacity: Double {
        didSet {
            defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity)
        }
    }

    var backgroundBlur: Double {
        didSet {
            defaults.set(backgroundBlur, forKey: Key.backgroundBlur)
        }
    }

    var cornerRadius: Double {
        didSet {
            defaults.set(cornerRadius, forKey: Key.cornerRadius)
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsTranslation = defaults.object(
            forKey: Key.showsTranslation
        ) as? Bool ?? false
        showsNextLine = defaults.object(
            forKey: Key.showsNextLine
        ) as? Bool ?? true

        dimCompletedLyrics = defaults.object(forKey: Key.dimCompletedLyrics) as? Bool ?? true
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""

        let storedFontScale = defaults.object(
            forKey: Key.fontScale
        ) as? Double ?? Self.defaultFontScale
        fontScale = min(
            max(storedFontScale, Self.fontScaleRange.lowerBound),
            Self.fontScaleRange.upperBound
        )
        textAlignment = FloatingLyricsTextAlignment(
            rawValue: defaults.string(forKey: Key.textAlignment) ?? ""
        ) ?? Self.defaultTextAlignment
        fontWeight = LyricsFontWeight(
            rawValue: defaults.string(forKey: Key.fontWeight) ?? ""
        ) ?? Self.defaultFontWeight
        textEffect = FloatingLyricsTextEffect(
            rawValue: defaults.string(forKey: Key.textEffect) ?? ""
        ) ?? Self.defaultTextEffect
        glowIntensity = Self.clampedValue(
            defaults.object(forKey: Key.glowIntensity) as? Double,
            fallback: Self.defaultGlowIntensity,
            range: Self.glowIntensityRange
        )
        glowRadius = Self.clampedValue(
            defaults.object(forKey: Key.glowRadius) as? Double,
            fallback: Self.defaultGlowRadius,
            range: Self.glowRadiusRange
        )
        textOpacity = Self.clampedValue(
            defaults.object(forKey: Key.textOpacity) as? Double,
            fallback: Self.defaultTextOpacity,
            range: Self.textOpacityRange
        )
        lineSpacing = Self.clampedValue(
            defaults.object(forKey: Key.lineSpacing) as? Double,
            fallback: Self.defaultLineSpacing,
            range: Self.lineSpacingRange
        )
        backgroundStyle = FloatingLyricsBackgroundStyle(
            rawValue: defaults.string(forKey: Key.backgroundStyle) ?? ""
        ) ?? Self.defaultBackgroundStyle
        backgroundOpacity = Self.clampedValue(
            defaults.object(forKey: Key.backgroundOpacity) as? Double,
            fallback: Self.defaultBackgroundOpacity,
            range: Self.backgroundOpacityRange
        )
        backgroundBlur = Self.clampedValue(
            defaults.object(forKey: Key.backgroundBlur) as? Double,
            fallback: Self.defaultBackgroundBlur,
            range: Self.backgroundBlurRange
        )
        cornerRadius = Self.clampedValue(
            defaults.object(forKey: Key.cornerRadius) as? Double,
            fallback: Self.defaultCornerRadius,
            range: Self.cornerRadiusRange
        )
    }

    func reset() {
        showsTranslation = false
        showsNextLine = true
        dimCompletedLyrics = true
        fontFamily = ""
        fontScale = Self.defaultFontScale
        textAlignment = Self.defaultTextAlignment
        fontWeight = Self.defaultFontWeight
        textEffect = Self.defaultTextEffect
        glowIntensity = Self.defaultGlowIntensity
        glowRadius = Self.defaultGlowRadius
        textOpacity = Self.defaultTextOpacity
        lineSpacing = Self.defaultLineSpacing
        backgroundStyle = Self.defaultBackgroundStyle
        backgroundOpacity = Self.defaultBackgroundOpacity
        backgroundBlur = Self.defaultBackgroundBlur
        cornerRadius = Self.defaultCornerRadius
    }

    private static func clampedValue(
        _ storedValue: Double?,
        fallback defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        min(
            max(storedValue ?? defaultValue, range.lowerBound),
            range.upperBound
        )
    }
}
