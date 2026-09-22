import SwiftUI

enum SpectrumColorMode: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case red = "Red"
    case blue = "Blue"
    case purple = "Purple"
    case white = "White"
    case acid = "Acid"
    case custom = "Custom"

    var id: String { rawValue }

    func color(at index: Int, total: Int, customColor: Color = USTheme.accent) -> Color {
        switch self {
        case .rgb:
            let denominator = max(1, total)
            return Color(hue: Double(index % denominator) / Double(denominator), saturation: 0.92, brightness: 1.0)
        case .red:
            return Color(red: 1.0, green: 0.06, blue: 0.14)
        case .blue:
            return Color(red: 0.14, green: 0.48, blue: 1.0)
        case .purple:
            return Color(red: 0.67, green: 0.18, blue: 1.0)
        case .white:
            return .white
        case .acid:
            return Color(red: 0.55, green: 1.0, blue: 0.08)
        case .custom:
            return customColor
        }
    }
}

struct SettingsView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var audio: AudioEngine

    var body: some View {
        SettingsContent(library: library, audio: audio, topPadding: 28, pageTitle: "SETTINGS")
    }
}

struct SpectrumSettingsView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsContent(library: library, audio: audio, topPadding: 20, pageTitle: "SETTINGS")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("UnSound Settings").font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SettingsContent: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var audio: AudioEngine
    let topPadding: CGFloat
    let pageTitle: String

    @AppStorage("iconSpectrumColorMode") private var iconModeRaw = SpectrumColorMode.white.rawValue
    @AppStorage("iconSpectrumCustomColorHex") private var iconCustomHex = "#FFFFFF"
    @AppStorage("iconGlowIntensity") private var iconGlow = 0.72
    @AppStorage("waveformIconColorHex") private var orbHex = "#FA0E21"

    @AppStorage("knobSpectrumColorMode") private var knobModeRaw = SpectrumColorMode.rgb.rawValue
    @AppStorage("knobSpectrumCustomColorHex") private var knobCustomHex = "#FF2342"
    @AppStorage("knobGlowIntensity") private var knobGlow = 0.68
    @AppStorage("knobAccentColorHex") private var knobAccentHex = "#FA0E21"

    @State private var expanded: SectionKind? = .bass
    @State private var showArtworkManager = false
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.english.rawValue

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .english
    }

    private let presetModes: [SpectrumColorMode] = [.rgb, .red, .blue, .purple, .white, .acid]

    private enum SectionKind: String {
        case language
        case orb
        case knob
        case bass
        case artwork
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white.opacity(0.84))
                            Text(AppLocalization.text(pageTitle))
                                .font(.system(size: 29, weight: .black))
                                .fontWidth(.condensed)
                                .tracking(0.8)
                        }
                        Text("Sound profile, interface, waveform and artwork.")
                            .font(.subheadline)
                            .foregroundStyle(USTheme.secondary)
                    }
                    .padding(.bottom, 4)

                    languageCard

                    sectionCard(.bass, title: "BASS OUTPUT", subtitle: audio.outputMode.rawValue, icon: "speaker.wave.3.fill") {
                        bassOutputContent
                    }

                    sectionCard(.orb, title: "WAVEFORM ORB", subtitle: "Circle + live bars", icon: "waveform.circle.fill") {
                        orbContent
                    }

                    sectionCard(.knob, title: "808 KNOB", subtitle: "Dial + frequency waveform", icon: "dial.high.fill") {
                        knobContent
                    }

                    Button {
                        showArtworkManager = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .usGlass(Circle(), tint: USTheme.accent.opacity(0.08))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("SONG ARTWORK")
                                    .font(.headline)
                                Text("Choose covers for one or many songs")
                                    .font(.caption)
                                    .foregroundStyle(USTheme.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(USTheme.tertiary)
                        }
                        .padding(16)
                        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true, tint: Color.white.opacity(0.015))
                    }
                    .buttonStyle(USPressStyle())

                    BrandFooter().padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.top, topPadding)
                .padding(.bottom, 116)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showArtworkManager) {
            NavigationStack {
                ArtworkManagerView(library: library, audio: audio)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showArtworkManager = false }.fontWeight(.semibold)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .usGlass(Circle(), tint: USTheme.accent.opacity(0.08))

                VStack(alignment: .leading, spacing: 3) {
                    Text("LANGUAGE")
                        .font(.headline)
                    Text("Choose the language used throughout UnSound.")
                        .font(.caption)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
            }

            ForEach(AppLanguage.allCases) { language in
                Button {
                    appLanguageRaw = language.rawValue
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: language.displayName)
                            .font(.subheadline.bold())
                        Spacer()
                        if selectedLanguage == language {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(USTheme.accent)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(
                        selectedLanguage == language ? Color.white.opacity(0.08) : Color.black.opacity(0.26),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        _ section: SectionKind,
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    expanded = expanded == section ? nil : section
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .usGlass(Circle(), tint: USTheme.accent.opacity(0.08))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalization.text(title)).font(.headline)
                        Text(AppLocalization.text(subtitle)).font(.caption).foregroundStyle(USTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded == section ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(USTheme.tertiary)
                }
                .padding(16)
            }
            .buttonStyle(USPressStyle())

            if expanded == section {
                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 16)
                content()
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var bassOutputContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tell UnSound what is actually making the bass. The EQ center frequencies and headroom change with the hardware.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)

            ForEach(BassOutputMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.20)) {
                        audio.outputMode = mode
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImage)
                            .font(.headline)
                            .frame(width: 34, height: 34)
                            .background(audio.outputMode == mode ? USTheme.accent.opacity(0.18) : Color.white.opacity(0.04), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.text(mode.rawValue)).font(.subheadline.bold())
                            Text(AppLocalization.text(mode.subtitle)).font(.caption2).foregroundStyle(USTheme.secondary)
                        }
                        Spacer()
                        if audio.outputMode == mode {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(USTheme.accent)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(USPressStyle())
            }
        }
    }

    private var orbContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                ReactiveSpectrumIcon(spectrum: audio.visualSpectrum, size: 112)
                Spacer()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Circle color").font(.subheadline.bold())
                    Text("Background behind the waveform").font(.caption2).foregroundStyle(USTheme.secondary)
                }
                Spacer()
                ColorPicker("Circle color", selection: colorBinding($orbHex), supportsOpacity: false)
                    .labelsHidden()
            }

            colorModeGrid(selection: $iconModeRaw, customHex: $iconCustomHex)
            glowControl(title: "Orb glow", value: $iconGlow)
        }
    }

    private var knobContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                AmpKnob(
                    value: .constant(18),
                    bassEnergy: max(0.18, audio.visualBassEnergy),
                    midEnergy: audio.visualMidEnergy,
                    highEnergy: audio.visualHighEnergy,
                    dominantFrequency: audio.dominantBassFrequency,
                    spectrum: audio.visualSpectrum,
                    onLongPress: {}
                )
                .allowsHitTesting(false)
                .scaleEffect(0.82)
                .frame(height: 190)
                Spacer()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Knob accent").font(.subheadline.bold())
                    Text("Dial, ticks and pointer").font(.caption2).foregroundStyle(USTheme.secondary)
                }
                Spacer()
                ColorPicker("Knob accent", selection: colorBinding($knobAccentHex), supportsOpacity: false)
                    .labelsHidden()
            }

            colorModeGrid(selection: $knobModeRaw, customHex: $knobCustomHex)
            glowControl(title: "Knob glow", value: $knobGlow)
        }
    }

    private func colorModeGrid(selection: Binding<String>, customHex: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waveform color").font(.subheadline.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(presetModes) { mode in
                    Button {
                        selection.wrappedValue = mode.rawValue
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(
                                    mode == .rgb
                                        ? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                                        : AnyShapeStyle(mode.color(at: 0, total: 1))
                                )
                                .frame(width: 13, height: 13)
                            Text(AppLocalization.text(mode.rawValue).uppercased())
                                .font(.system(size: 9, weight: .black, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selection.wrappedValue == mode.rawValue ? Color.white.opacity(0.08) : Color.white.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                    }
                    .buttonStyle(USPressStyle())
                }

                ColorPicker("Custom waveform color", selection: Binding(
                    get: { .unsoundHex(customHex.wrappedValue) },
                    set: {
                        customHex.wrappedValue = $0.unsoundHexString
                        selection.wrappedValue = SpectrumColorMode.custom.rawValue
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    selection.wrappedValue == SpectrumColorMode.custom.rawValue ? Color.white.opacity(0.08) : Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
            }
        }
    }

    private func glowControl(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.text(title)).font(.subheadline.bold())
                Spacer()
                Text(value.wrappedValue <= 0.01 ? "OFF" : "\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(value.wrappedValue <= 0.01 ? USTheme.tertiary : USTheme.accent)
            }
            Slider(value: value, in: 0...1)
                .tint(USTheme.accent)
            Text("Drag fully left to turn the glow off.")
                .font(.caption2)
                .foregroundStyle(USTheme.tertiary)
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { .unsoundHex(hex.wrappedValue) },
            set: { hex.wrappedValue = $0.unsoundHexString }
        )
    }
}
