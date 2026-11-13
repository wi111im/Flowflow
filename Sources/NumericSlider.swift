import SwiftUI

/// Keeps the slider and editable value in the same units, clamping typed values.
struct NumericSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var scale: Double = 1
    var suffix: String = ""
    let label: String

    private var displayedValue: Binding<Double> {
        Binding(get: { value * scale }, set: { input in
            guard input.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, input / scale))
        })
    }
    var body: some View {
        HStack(spacing: 6) {
            if let step {
                Slider(value: $value, in: range, step: step).accessibilityLabel(label)
            } else {
                Slider(value: $value, in: range).accessibilityLabel(label)
            }
            TextField(label, value: displayedValue, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 58).accessibilityLabel("\(label)数值")
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
        }
    }
}
