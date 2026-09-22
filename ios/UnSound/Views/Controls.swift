import SwiftUI

struct GlassPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .usGlass(Capsule(), interactive: true)
    }
}

struct AmpKnob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...30
    var bassEnergy: Double = 0
    var midEnergy: Double = 0
    var highEnergy: Double = 0
    var dominantFrequency: Double = 0
    var spectrum: [Double] = []
    var reducedVisuals: Bool = false
    var onLongPress: () -> Void

    @AppStorage("knobSpectrumColorMode") private var spectrumColorModeRaw = SpectrumColorMode.rgb.rawValue
    @AppStorage("knobGlowIntensity") private var glowIntensity = 0.68
    @AppStorage("knobSpectrumCustomColorHex") private var spectrumCustomColorHex = "#FF2342"
    @AppStorage("knobAccentColorHex") private var knobAccentColorHex = "#FA0E21"

    private let knobSize: CGFloat = 136
    private var visualizerCount: Int { reducedVisuals ? 10 : 24 }

    private var normalized: Double {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var angleDegrees: Double { -140 + normalized * 280 }
    private var bass: CGFloat { CGFloat(min(1, max(0, bassEnergy))) }
    private var mids: CGFloat { CGFloat(min(1, max(0, midEnergy))) }
    private var highs: CGFloat { CGFloat(min(1, max(0, highEnergy))) }
    private var glow: Double { reducedVisuals ? 0 : min(1, max(0, glowIntensity)) }

    private var spectrumMode: SpectrumColorMode {
        SpectrumColorMode(rawValue: spectrumColorModeRaw) ?? .rgb
    }

    private var customSpectrumColor: Color {
        .unsoundHex(spectrumCustomColorHex)
    }

    private var knobAccent: Color {
        .unsoundHex(knobAccentColorHex)
    }

    private var frequencyAngle: Double {
        guard dominantFrequency > 0 else { return -140 }
        let clamped = min(145, max(35, dominantFrequency))
        return -140 + ((clamped - 35) / 110) * 280
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                liveFrequencyLines

                Circle()
                    .stroke(knobAccent.opacity(0.08 + Double(bass) * 0.28), lineWidth: 1.0 + bass * 2.6)
                    .frame(width: knobSize + 18, height: knobSize + 18)
                    .scaleEffect(reducedVisuals ? 1 : 1 + bass * 0.045)
                    .blur(radius: reducedVisuals ? 0 : 0.4 + bass * 1.8)

                ForEach(0..<31, id: \.self) { tick in
                    Capsule()
                        .fill(tick <= Int(normalized * 30.0) ? knobAccent.opacity(0.95) : Color.white.opacity(0.12))
                        .frame(width: tick % 5 == 0 ? 2.4 : 1.2, height: tick % 5 == 0 ? 10 : 6)
                        .offset(y: -(knobSize / 2 - 5))
                        .rotationEffect(.degrees(-140 + Double(tick) / 30.0 * 280.0))
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.13 + Double(highs) * 0.05), Color.black.opacity(0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.10 + Double(highs) * 0.08), lineWidth: 1))
                    .shadow(color: knobAccent.opacity((0.10 + Double(bass) * 0.18) * glow), radius: (8 + bass * 10) * glow)
                    .padding(15)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                knobAccent.opacity(0.16 + Double(bass) * 0.32),
                                knobAccent.opacity(0.04 + Double(mids) * 0.08),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 44
                        )
                    )
                    .frame(width: 78, height: 78)
                    .scaleEffect(x: 1 + bass * 0.04, y: reducedVisuals ? 1 : 1 + bass * 0.09)
                    .blur(radius: reducedVisuals ? 0 : bass)

                Capsule()
                    .fill(knobAccent)
                    .frame(width: 4, height: 34)
                    .offset(y: -35)
                    .rotationEffect(.degrees(angleDegrees))
                    .shadow(color: knobAccent.opacity(0.75 * glow), radius: 2 + 7 * glow)

                if dominantFrequency > 0 {
                    let markerColor = spectrumMode.color(
                        at: Int(max(0, min(Double(visualizerCount - 1), dominantFrequency / 145.0 * Double(visualizerCount - 1)))),
                        total: visualizerCount,
                        customColor: customSpectrumColor
                    )
                    Circle()
                        .fill(markerColor)
                        .frame(width: 7 + bass * 3, height: 7 + bass * 3)
                        .offset(y: -(knobSize / 2 + 5))
                        .rotationEffect(.degrees(frequencyAngle))
                        .shadow(color: markerColor.opacity(0.85 * glow), radius: (2 + bass * 4) * glow)
                }

                VStack(spacing: 2) {
                    Text("808")
                        .font(.caption.bold())
                        .tracking(1.2)
                    Text(String(format: "+%.0f", value))
                        .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(dominantFrequency > 0 ? String(format: "%.0f Hz", dominantFrequency) : "dB")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(dominantFrequency > 0 ? knobAccent.opacity(0.92) : USTheme.secondary)
                }
                .foregroundStyle(.white)
            }
            .frame(width: knobSize + 78, height: knobSize + 78)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        updateValue(at: gesture.location)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.55)
                    .onEnded { _ in onLongPress() }
            )
            .sensoryFeedback(.selection, trigger: Int(value.rounded()))
            .animation(reducedVisuals ? nil : .linear(duration: 0.06), value: spectrum)
            .animation(reducedVisuals ? nil : .linear(duration: 0.07), value: bassEnergy)
            .animation(reducedVisuals ? nil : .linear(duration: 0.07), value: midEnergy)
            .animation(reducedVisuals ? nil : .linear(duration: 0.07), value: highEnergy)
            .animation(reducedVisuals ? nil : .linear(duration: 0.08), value: dominantFrequency)

            Text(AppLocalization.text(dominantFrequency > 0 ? "Live spectrum • drag to tune" : "Drag around the dial • hold for exact value"))
                .font(.caption2)
                .foregroundStyle(USTheme.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("808 boost")
        .accessibilityValue(
            dominantFrequency > 0
                ? String(format: "plus %.1f decibels, live bass %.0f hertz", value, dominantFrequency)
                : String(format: "plus %.1f decibels", value)
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private var liveFrequencyLines: some View {
        ZStack {
            ForEach(0..<visualizerCount, id: \.self) { index in
                let rawLevel = index < spectrum.count ? spectrum[index] : 0
                let level = CGFloat(min(1, max(0, rawLevel)))
                let color = spectrumMode.color(at: index, total: visualizerCount, customColor: customSpectrumColor)
                let lineHeight = 7 + level * (reducedVisuals ? 18 : 30)

                Capsule()
                    .fill(color.opacity(0.50 + Double(level) * 0.50))
                    .frame(width: 2.4 + level * 0.8, height: lineHeight)
                    .offset(y: -(knobSize / 2 + 24 + lineHeight / 2))
                    .rotationEffect(.degrees(Double(index) / Double(visualizerCount) * 360.0))
                    .shadow(
                        color: color.opacity((0.16 + Double(level) * 0.58) * glow),
                        radius: (2 + level * 7) * glow
                    )
            }
        }
        .scaleEffect(reducedVisuals ? 1 : 1 + bass * 0.012)
    }

    private func updateValue(at point: CGPoint) {
        let side = knobSize + 78
        let center = CGPoint(x: side / 2, y: side / 2)
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)

        let raw = atan2(dx, -dy) * 180 / .pi
        let clampedAngle = min(140.0, max(-140.0, raw))
        let fraction = (clampedAngle + 140.0) / 280.0
        let newValue = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        value = min(range.upperBound, max(range.lowerBound, newValue))
    }
}

struct TrackRow: View {
    var track: Track
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [USTheme.accent.opacity(0.16), Color.white.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "waveform").foregroundStyle(USTheme.accent.opacity(0.9)))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(USTheme.secondary).lineLimit(1)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 5)
    }
}
