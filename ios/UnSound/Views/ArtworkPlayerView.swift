import SwiftUI
import UIKit

struct ArtworkPlayerView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPlaylistPicker = false

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(spacing: 22) {
                    header

                    if let track = audio.currentTrack {
                        cover(track)

                        VStack(spacing: 5) {
                            Text(track.title)
                                .font(.system(size: 27, weight: .black, design: .rounded))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)

                            Text(track.artist)
                                .font(.headline)
                                .foregroundStyle(USTheme.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)

                        progress
                        controls
                        libraryActions(track)
                    } else {
                        Text("No track playing")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .padding(.top, 160)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showPlaylistPicker) {
            if let id = audio.currentTrack?.id {
                PlaylistPicker(trackID: id, library: library)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true, tint: Color.black.opacity(0.16))
            }
            .buttonStyle(USPressStyle())
            .accessibilityLabel("Back")

            Spacer()

            Text("NOW PLAYING")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(USTheme.secondary)

            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.top, 5)
    }

    @ViewBuilder
    private func cover(_ track: Track) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [USTheme.accentDeep.opacity(0.72), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let localURL = library.customArtworkURL(for: track),
               let image = UIImage(contentsOfFile: localURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let artworkURL = track.artworkURL,
                      let url = URL(string: artworkURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderCover
                }
            } else {
                placeholderCover
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.075)))
        .shadow(
            color: audio.performanceLimited ? .clear : .black.opacity(0.55),
            radius: audio.performanceLimited ? 0 : 30,
            y: audio.performanceLimited ? 0 : 16
        )
        .onTapGesture(count: 2) { library.like(track.id) }
    }

    private var placeholderCover: some View {
        ZStack {
            Color.black
            ReactiveSpectrumIcon(
                spectrum: audio.visualSpectrum,
                size: 104,
                reducedVisuals: audio.performanceLimited
            )
        }
    }

    private var progress: some View {
        VStack(spacing: 7) {
            Slider(
                value: Binding(
                    get: { min(audio.currentTime, max(audio.duration, 0)) },
                    set: { audio.seek(to: $0) }
                ),
                in: 0...max(audio.duration, 0.01)
            )
            .tint(.white)

            HStack {
                Text(time(audio.currentTime))
                Spacer()
                Text("-" + time(max(0, audio.duration - audio.currentTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(USTheme.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            controlButton(repeatIcon, active: audio.repeatMode != .off) {
                player.cycleRepeatMode()
            }
            controlButton("backward.end.fill") { player.previous() }

            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 29, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.24))
            }
            .buttonStyle(USPressStyle())
            .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")

            controlButton("forward.end.fill") { player.next() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func libraryActions(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                library.toggleLike(track.id)
            } label: {
                Label(currentIsLiked ? "LIKED" : "LIKE", systemImage: currentIsLiked ? "heart.fill" : "heart")
                    .font(.caption.bold())
                    .foregroundStyle(currentIsLiked ? USTheme.accent : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true, tint: currentIsLiked ? USTheme.accent.opacity(0.10) : nil)
            }
            .buttonStyle(USPressStyle())

            Button {
                showPlaylistPicker = true
            } label: {
                Label("PLAYLIST", systemImage: "plus")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)
            }
            .buttonStyle(USPressStyle())
        }
    }

    private func controlButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(active ? USTheme.accent : .white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(USPressStyle())
    }

    private var currentIsLiked: Bool {
        guard let id = audio.currentTrack?.id else { return false }
        return library.track(id)?.isLiked == true
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
