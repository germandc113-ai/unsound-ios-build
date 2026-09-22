import SwiftUI

/// Compact FL-style live spectrum used inside the UnSound audio orb.
struct ReactiveSpectrumIcon: View {
    var spectrum: [Double]
    var size: CGFloat = 86
    var reducedVisuals: Bool = false

    @AppStorage("iconSpectrumColorMode") private var spectrumColorModeRaw = SpectrumColorMode.white.rawValue
    @AppStorage("iconSpectrumCustomColorHex") private var spectrumCustomColorHex = "#FFFFFF"
    @AppStorage("iconGlowIntensity") private var glowIntensity = 0.72
    @AppStorage("waveformIconColorHex") private var waveformIconColorHex = "#FA0E21"

    private var barCount: Int { reducedVisuals ? 7 : 13 }

    private var mode: SpectrumColorMode {
        SpectrumColorMode(rawValue: spectrumColorModeRaw) ?? .white
    }

    private var customSpectrumColor: Color {
        .unsoundHex(spectrumCustomColorHex)
    }

    private var orbColor: Color {
        .unsoundHex(waveformIconColorHex)
    }

    private var glow: Double {
        reducedVisuals ? 0 : min(1, max(0, glowIntensity))
    }

    private var spectrumAnimation: Animation? {
        reducedVisuals ? nil : .linear(duration: 0.05)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(orbColor)

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let usableWidth = width * 0.64
                let usableHeight = height * 0.58
                let spacing = usableWidth * 0.035
                let barWidth = max(2.0, (usableWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let sourceIndex = mappedIndex(index)
                        let raw = sourceIndex < spectrum.count ? spectrum[sourceIndex] : 0
                        let level = CGFloat(min(1, max(0, raw)))
                        let shaped = pow(level, 0.72)
                        let barHeight = max(usableHeight * 0.12, usableHeight * shaped)
                        let color = mode.color(at: index, total: barCount, customColor: customSpectrumColor)

                        Capsule()
                            .fill(color)
                            .frame(width: barWidth, height: barHeight)
                            .shadow(
                                color: glow > 0 ? color.opacity((0.26 + Double(level) * 0.62) * glow) : .clear,
                                radius: glow > 0 ? (2.0 + level * 5.0) * glow : 0
                            )
                    }
                }
                .frame(width: usableWidth, height: usableHeight, alignment: .center)
                .position(x: width / 2, y: height / 2)
            }
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .shadow(color: orbColor.opacity(0.28 * glow), radius: 4 + 10 * glow)
        .animation(spectrumAnimation, value: spectrum)
        .animation(reducedVisuals ? nil : .easeInOut(duration: 0.18), value: waveformIconColorHex)
        .animation(reducedVisuals ? nil : .easeInOut(duration: 0.18), value: spectrumColorModeRaw)
        .animation(reducedVisuals ? nil : .easeInOut(duration: 0.18), value: spectrumCustomColorHex)
        .accessibilityHidden(true)
    }

    private func mappedIndex(_ index: Int) -> Int {
        guard !spectrum.isEmpty else { return 0 }
        if barCount <= 1 { return 0 }
        let fraction = Double(index) / Double(barCount - 1)
        return min(spectrum.count - 1, Int((fraction * Double(spectrum.count - 1)).rounded()))
    }
}
