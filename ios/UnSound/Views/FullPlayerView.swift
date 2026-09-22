import SwiftUI

struct FullPlayerView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPlaylistPicker = false
    @State private var showManualDB = false
    @State private var manualDB = ""
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @AppStorage("fullPlayerVisualMode") private var visualModeRaw = FullPlayerVisualMode.both.rawValue

    private var visualMode: FullPlayerVisualMode {
        FullPlayerVisualMode(rawValue: visualModeRaw) ?? .both
    }

    private var activeLyricIndex: Int? {
        player.lyrics.lastIndex(where: { $0.time <= audio.currentTime })
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : min(audio.currentTime, max(audio.duration, 0))
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(spacing: 23) {
                    header

                    if let track = audio.currentTrack {
                        visualModePicker
                        artwork(track)
                        metadata(track)
                        progress
                        transport
                        bassSection(track)
                        lyricsCard
                        BrandFooter().padding(.top, 2)
                    } else {
                        Text("No track playing")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .padding(.top, 120)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPlaylistPicker) {
            if let id = audio.currentTrack?.id {
                PlaylistPicker(trackID: id, library: library)
            }
        }
        .fullScreenCover(isPresented: $player.showLyrics) {
            FullLyricsView(player: player, audio: audio)
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
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.bold())
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true)
            }
            .buttonStyle(USPressStyle())

            Spacer()

            VStack(spacing: 2) {
                Text("NOW PLAYING")
                    .font(.caption2.bold())
                    .tracking(1.8)
                    .foregroundStyle(USTheme.secondary)
                Text("UnSound")
                    .font(.headline)
            }

            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    private func artwork(_ track: Track) -> some View {
        TrackHeroArtwork(
            track: track,
            audio: audio,
            library: library,
            cornerRadius: 30,
            visualMode: visualMode,
            spectrumSize: 174
        )
            .onTapGesture(count: 2) { library.like(track.id) }
    }

    private var visualModePicker: some View {
        Picker(AppLocalization.text("PLAYER VIEW"), selection: $visualModeRaw) {
            ForEach(FullPlayerVisualMode.allCases) { mode in
                Text(AppLocalization.text(mode.rawValue)).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(AppLocalization.text("PLAYER VIEW"))
    }

    private func metadata(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.title2.bold()).lineLimit(2)
                Text(track.artist).font(.headline).foregroundStyle(USTheme.secondary).lineLimit(1)
            }
            Spacer()

            Button { library.toggleLike(track.id) } label: {
                Image(systemName: library.track(track.id)?.isLiked == true ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(library.track(track.id)?.isLiked == true ? USTheme.accent : .white)
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true)
            }
            .buttonStyle(USPressStyle())

            Button { showPlaylistPicker = true } label: {
                Image(systemName: "plus")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true)
            }
            .buttonStyle(USPressStyle())
        }
    }

    private var progress: some View {
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

    private var transport: some View {
        HStack(spacing: 23) {
            transportButton(repeatIcon, active: audio.repeatMode != .off) {
                player.cycleRepeatMode()
            }
            transportButton("backward.end.fill") { player.previous() }

            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .frame(width: 68, height: 68)
                    .foregroundStyle(.white)
                    .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.28))
            }
            .buttonStyle(USPressStyle())

            transportButton("forward.end.fill") { player.next() }
            transportButton("quote.bubble") { player.showLyrics = true }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(active ? USTheme.accent : .white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(USPressStyle())
    }

    private func bassSection(_ track: Track) -> some View {
        VStack(spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("808 BOOST").font(.headline)
                    Text(AppLocalization.text(track.selectedPresetID == nil ? "Manual tuning" : "Preset active"))
                        .font(.caption2)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
                Button {
                    manualDB = String(format: "%.1f", audio.bassDB)
                    showManualDB = true
                } label: {
                    Text(String(format: "+%.1f dB", audio.bassDB))
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(USTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
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
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.065)))
    }

    private var lyricsCard: some View {
        Button {
            player.showLyrics = true
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Lyrics").font(.title3.bold())
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(USTheme.secondary)
                }
                .foregroundStyle(.white)

                if player.lyrics.isEmpty {
                    Text("No synced lyrics found yet.")
                        .font(.headline)
                        .foregroundStyle(USTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                } else {
                    let index = activeLyricIndex ?? 0
                    let lower = max(0, index - 1)
                    let upper = min(player.lyrics.count, index + 3)
                    ForEach(Array(player.lyrics[lower..<upper])) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: line.id == player.lyrics[index].id ? 24 : 20, weight: line.id == player.lyrics[index].id ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(line.id == player.lyrics[index].id ? .white : .white.opacity(0.35))
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [USTheme.accentDeep.opacity(0.44), Color.black.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.07)))
        }
        .buttonStyle(USPressStyle())
    }

    private var repeatIcon: String {
        switch audio.repeatMode {
        case .off, .playlist: return "repeat"
        case .track: return "repeat.1"
        }
    }

    private func time(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
