import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @ObservedObject var library: LibraryStore
    @State private var manualDB = ""
    @State private var showManualDB = false
    @State private var showPresetName = false
    @State private var newPresetName = ""
    @State private var showSettings = false
    @State private var showArtworkPlayer = false
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var displayedTime: Double {
        isScrubbing ? scrubTime : min(audio.currentTime, max(audio.duration, 0))
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(spacing: 20) {
                    if let track = audio.currentTrack {
                        tuningSection(track)
                        compactNowPlaying(track)
                        progressSection
                    } else {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(USTheme.accent.opacity(0.10)).frame(width: 104, height: 104)
                                Image(systemName: "waveform")
                                    .font(.system(size: 48))
                                    .foregroundStyle(USTheme.accent)
                            }
                            Text("No track playing").font(.title2.bold())
                            Text("Start a song to bring the 808 control surface alive.")
                                .foregroundStyle(USTheme.secondary)
                                .multilineTextAlignment(.center)

                            Button { showSettings = true } label: {
                                Label("UnSound Settings", systemImage: "slider.horizontal.3")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .usGlass(Capsule(), interactive: true)
                            }
                            .buttonStyle(USPressStyle())
                        }
                        .padding(.top, 105)
                    }

                    BrandFooter()
                        .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.top, 82)
                .padding(.bottom, 108)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showSettings) {
            SpectrumSettingsView(library: library, audio: audio)
        }
        .fullScreenCover(isPresented: $showArtworkPlayer) {
            ArtworkPlayerView(player: player, audio: audio, library: library)
                .interactiveDismissDisabled(true)
        }
        .alert("Bass Boost", isPresented: $showManualDB) {
            TextField("dB", text: $manualDB).keyboardType(.decimalPad)
            Button("Set") {
                if let value = Double(manualDB.replacingOccurrences(of: ",", with: ".")) {
                    player.setBassDB(value)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a value from 0 to +30 dB.")
        }
        .alert("New preset", isPresented: $showPresetName) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                if !newPresetName.isEmpty {
                    player.saveCurrentAsPreset(name: newPresetName)
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func compactNowPlaying(_ track: Track) -> some View {
        Button {
            showArtworkPlayer = true
        } label: {
            HStack(spacing: 13) {
                TrackHeroArtwork(track: track, audio: audio, library: library, cornerRadius: 16)
                    .frame(width: 72, height: 72)
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(USTheme.secondary)
                        .lineLimit(1)
                    Text("OPEN FULL PLAYER")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(USTheme.accent)
                }

                Spacer()

                Button { player.showLyrics = true } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                        .usGlass(Circle(), interactive: true)
                }
                .buttonStyle(USPressStyle())

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(USTheme.tertiary)
            }
            .padding(12)
            .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(USTheme.hairline))
        }
        .buttonStyle(USPressStyle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                library.like(track.id)
            }
        )
    }

    private var progressSection: some View {
        VStack(spacing: 7) {
            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(audio.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = min(audio.currentTime, max(audio.duration, 0))
                        isScrubbing = true
                    } else {
                        let target = scrubTime
                        isScrubbing = false
                        audio.seek(to: target)
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(time(displayedTime))
                Spacer()
                Text("-" + time(max(0, audio.duration - displayedTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(USTheme.secondary)
        }
    }

    private func tuningSection(_ track: Track) -> some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("808 CONTROL")
                        .font(.headline)
                    Text(AppLocalization.text(audio.dominantBassFrequency > 0 ? "Live spectrum active" : (track.selectedPresetID == nil ? "Custom tuning" : "Preset active")))
                        .font(.caption2)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 38)
                        .usGlass(Circle(), interactive: true)
                }
                .buttonStyle(USPressStyle())

                Button {
                    manualDB = String(format: "%.1f", audio.bassDB)
                    showManualDB = true
                } label: {
                    Text(String(format: "+%.1f dB", audio.bassDB))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(USTheme.accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .usGlass(Capsule(), interactive: true, tint: USTheme.accent.opacity(0.10))
                }
                .buttonStyle(USPressStyle())
            }

            AmpKnob(
                value: Binding(
                    get: { audio.bassDB },
                    set: { player.setBassDB($0) }
                ),
                bassEnergy: audio.visualBassEnergy,
                midEnergy: audio.visualMidEnergy,
                highEnergy: audio.visualHighEnergy,
                dominantFrequency: audio.dominantBassFrequency,
                spectrum: audio.visualSpectrum,
                reducedVisuals: audio.performanceLimited,
                onLongPress: {
                    manualDB = String(format: "%.1f", audio.bassDB)
                    showManualDB = true
                }
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(track.presets) { preset in
                        Button(preset.name) { player.choosePreset(preset) }
                            .font(.caption.bold())
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .usGlass(
                                Capsule(),
                                interactive: true,
                                tint: track.selectedPresetID == preset.id ? USTheme.accent.opacity(0.28) : nil
                            )
                            .buttonStyle(USPressStyle())
                    }

                    Button("+ New") {
                        newPresetName = ""
                        showPresetName = true
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .usGlass(Capsule(), interactive: true)
                    .buttonStyle(USPressStyle())
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 12) {
                effectSlider(
                    "Distortion",
                    value: Binding(get: { audio.distortionAmount }, set: { player.setDistortion($0) }),
                    range: 0...100
                )
                effectSlider(
                    "Reverb",
                    value: Binding(get: { audio.reverbAmount }, set: { player.setReverb($0) }),
                    range: 0...100
                )
            }

            effectSlider(
                "Speed",
                value: Binding(get: { audio.speed }, set: { player.setSpeed($0) }),
                range: 0.5...2
            )
        }
        .padding(18)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.065)))
    }

    private func effectSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(USTheme.secondary)
            Slider(value: value, in: range)
                .tint(USTheme.accent)
        }
    }

    private func time(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct QuickHomeSuggestions: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerCoordinator
    @State private var query = ""

    private var filtered: [Track] {
        let visible = library.tracks.filter { !library.isSuggestionHidden($0.id) }
        return query.isEmpty
            ? Array(visible.prefix(8))
            : visible.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.artist.localizedCaseInsensitiveContains(query)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(USTheme.secondary)
                TextField("Quick search", text: $query)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)

            HStack {
                Text("Similar / recent").font(.headline)
                Spacer()
                Text("− hides")
                    .font(.caption2.bold())
                    .foregroundStyle(USTheme.tertiary)
            }

            ForEach(filtered) { track in
                HStack(spacing: 8) {
                    Button { player.play(track, queue: filtered) } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(USPressStyle())

                    Button {
                        withAnimation(.snappy(duration: 0.20)) {
                            library.hideSuggestion(track.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.52))
                            .frame(width: 42, height: 42)
                            .usGlass(Circle(), interactive: true, tint: Color.black.opacity(0.08))
                    }
                    .buttonStyle(USPressStyle())
                    .accessibilityLabel("Do not suggest this song again")
                }
            }

            if filtered.isEmpty {
                Text(AppLocalization.text(query.isEmpty ? "No more suggestions right now." : "No visible matches."))
                    .font(.caption)
                    .foregroundStyle(USTheme.tertiary)
                    .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}
