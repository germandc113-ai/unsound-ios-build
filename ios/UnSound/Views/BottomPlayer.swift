import SwiftUI
import UIKit

struct BottomPlayer: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @ObservedObject var library: LibraryStore
    @ObservedObject var sync: SyncCoordinator

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var displayedTime: Double {
        isScrubbing ? scrubTime : min(audio.currentTime, max(audio.duration, 0))
    }

    var body: some View {
        if let track = audio.currentTrack {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        player.showFullPlayer = true
                    } label: {
                        HStack(spacing: 12) {
                            artwork(track, size: 54)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(USTheme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(USPressStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        library.toggleLike(track.id)
                    } label: {
                        Image(systemName: library.track(track.id)?.isLiked == true ? "heart.fill" : "heart")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(library.track(track.id)?.isLiked == true ? USTheme.accent : .white)
                            .frame(width: 42, height: 42)
                            .usGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(USPressStyle())
                    .accessibilityLabel("Like song")
                }

                VStack(spacing: 3) {
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
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(USTheme.secondary)
                }

                HStack(spacing: 24) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(USPressStyle())

                    Button { audio.toggle() } label: {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .black))
                            .frame(width: 52, height: 52)
                            .foregroundStyle(.white)
                            .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.22))
                    }
                    .buttonStyle(USPressStyle())

                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(USPressStyle())
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 10)
            .background(Color.black.opacity(0.80))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
            }
        }
    }

    @ViewBuilder
    private func artwork(_ track: Track, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [USTheme.accentDeep.opacity(0.75), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing))

            if let image = library.customArtworkImage(for: track) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let artworkURL = track.artworkURL, let url = URL(string: artworkURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "waveform").foregroundStyle(USTheme.accent)
                }
            } else {
                Image(systemName: "waveform").foregroundStyle(USTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).stroke(Color.white.opacity(0.07)))
    }

    private func time(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct PlaylistPicker: View {
    let trackID: UUID
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var liked = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    liked.toggle()
                } label: {
                    HStack {
                        Label("Liked Songs", systemImage: "heart.fill")
                        Spacer()
                        if liked {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(USTheme.accent)
                        }
                    }
                }

                ForEach(library.playlists) { playlist in
                    Button {
                        if selected.contains(playlist.id) {
                            selected.remove(playlist.id)
                        } else {
                            selected.insert(playlist.id)
                        }
                    } label: {
                        HStack {
                            Text(playlist.title)
                            Spacer()
                            if selected.contains(playlist.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(USTheme.accent)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Add to…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept (\(selected.count + (liked ? 1 : 0)))") {
                        if liked { library.like(trackID) } else { library.unlike(trackID) }
                        for playlist in library.playlists {
                            library.setTrack(trackID, inPlaylist: playlist.id, included: selected.contains(playlist.id))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                liked = library.track(trackID)?.isLiked == true
                selected = Set(library.playlists.filter { $0.trackIDs.contains(trackID) }.map(\.id))
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
