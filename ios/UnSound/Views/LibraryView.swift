import SwiftUI
import UIKit

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerCoordinator
    @State private var newPlaylist = ""
    @State private var createPlaylist = false
    @State private var selectedPlaylist: Playlist? = nil
    @State private var showReplay = false

    private var ordered: [Playlist] {
        library.playlists.sorted { ($0.isPinned ? 0 : 1, $0.title) < ($1.isPinned ? 0 : 1, $1.title) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Playlists")
                                    .font(.largeTitle.bold())
                                Text("Your local UnSound collection")
                                    .font(.caption)
                                    .foregroundStyle(USTheme.secondary)
                            }
                            Spacer()
                            Button { createPlaylist = true } label: {
                                Image(systemName: "plus")
                                    .font(.headline.bold())
                                    .frame(width: 44, height: 44)
                                    .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.10))
                            }
                            .buttonStyle(USPressStyle())
                        }

                        Button {
                            selectedPlaylist = Playlist(title: "Liked Songs", trackIDs: library.likedTracks.map(\.id), isPinned: true)
                        } label: {
                            libraryCard(title: "Liked Songs", subtitle: "\(library.likedTracks.count) songs", icon: "heart.fill", pinned: true)
                        }
                        .buttonStyle(USPressStyle())

                        ForEach(ordered) { playlist in
                            Button { selectedPlaylist = playlist } label: {
                                libraryCard(
                                    title: playlist.title,
                                    subtitle: "\(playlist.trackIDs.count) songs",
                                    icon: "music.note.list",
                                    pinned: playlist.isPinned
                                )
                            }
                            .buttonStyle(USPressStyle())
                            .contextMenu {
                                Button(playlist.isPinned ? "Unpin" : "Pin") {
                                    library.togglePinned(playlist.id)
                                }
                            }
                        }

                        Button { showReplay = true } label: {
                            ReplayCard(library: library)
                        }
                        .buttonStyle(USPressStyle())

                        BrandFooter().padding(.top, 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 30)
                    .padding(.bottom, 160)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("New playlist", isPresented: $createPlaylist) {
                TextField("Playlist name", text: $newPlaylist)
                Button("Create") {
                    if !newPlaylist.isEmpty {
                        library.createPlaylist(title: newPlaylist)
                        newPlaylist = ""
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(item: $selectedPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, library: library, player: player)
            }
            .sheet(isPresented: $showReplay) {
                NavigationStack {
                    ReplayView(library: library)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showReplay = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private func libraryCard(title: String, subtitle: String, icon: String, pinned: Bool) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [USTheme.accent.opacity(0.16), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 68, height: 68)
                .overlay(Image(systemName: icon).font(.title2).foregroundStyle(USTheme.accent))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.055)))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.headline)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(USTheme.accent)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(USTheme.tertiary)
        }
        .padding(12)
        .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerCoordinator
    @Environment(\.dismiss) var dismiss
    @State private var keepBottomAfterAdd = false
    @State private var query = ""
    @State private var reorderMode = false

    private let recommendationBottomID = "playlist-recommendations-bottom"

    private var tracks: [Track] {
        if playlist.title == "Liked Songs" { return library.likedTracks }
        if let fresh = library.playlists.first(where: { $0.id == playlist.id }) {
            return library.tracks(in: fresh)
        }
        return library.tracks(in: playlist)
    }

    private var visibleTracks: [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.artist.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var recommendations: [Track] {
        let ids = Set(tracks.map(\.id))
        let artists = Set(tracks.map { $0.artist.lowercased() })
        let ranked = library.tracks
            .filter { !ids.contains($0.id) && !library.isSuggestionHidden($0.id) }
            .sorted { a, b in
                (artists.contains(a.artist.lowercased()) ? 0 : 1, a.dateAdded) <
                (artists.contains(b.artist.lowercased()) ? 0 : 1, b.dateAdded)
            }
        return Array(ranked.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.title).font(.largeTitle.bold())
                                    Text("\(tracks.count) songs").foregroundStyle(USTheme.secondary)
                                }
                                Spacer()
                                Button {
                                    withAnimation(.snappy(duration: 0.20)) { reorderMode.toggle() }
                                } label: {
                                    Label(reorderMode ? "Done" : "Reorder", systemImage: "arrow.up.arrow.down")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .usGlass(Capsule(), interactive: true, tint: reorderMode ? USTheme.accent.opacity(0.12) : nil)
                                }
                                .buttonStyle(USPressStyle())
                            }

                            searchField

                            if visibleTracks.isEmpty {
                                Text(AppLocalization.text(query.isEmpty ? "No songs yet." : "No songs match your search."))
                                    .font(.caption)
                                    .foregroundStyle(USTheme.tertiary)
                                    .padding(.vertical, 10)
                            }

                            ForEach(visibleTracks) { track in
                                playlistTrackRow(track)
                            }

                            Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 12)
                            Text("Recommended for this playlist").font(.title3.bold())
                            Text("▶ previews. + adds. − hides a song from future suggestions.")
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)

                            ForEach(recommendations) { track in
                                HStack(spacing: 8) {
                                    PlaylistArtworkThumb(track: track, library: library, size: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).font(.subheadline.bold()).lineLimit(1)
                                        Text(track.artist).font(.caption).foregroundStyle(USTheme.secondary).lineLimit(1)
                                    }
                                    Spacer()

                                    Button { player.preview(track, seconds: 12) } label: {
                                        Image(systemName: player.previewingTrackID == track.id ? "stop.circle.fill" : "play.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(player.previewingTrackID == track.id ? .white : USTheme.accent)
                                    }
                                    .buttonStyle(USPressStyle())

                                    Button {
                                        keepBottomAfterAdd = true
                                        if playlist.title == "Liked Songs" { library.like(track.id) }
                                        else { library.setTrack(track.id, inPlaylist: playlist.id, included: true) }
                                    } label: {
                                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(USTheme.accent)
                                    }
                                    .buttonStyle(USPressStyle())

                                    Button {
                                        withAnimation(.snappy(duration: 0.20)) { library.hideSuggestion(track.id) }
                                    } label: {
                                        Image(systemName: "minus.circle").font(.title2).foregroundStyle(.white.opacity(0.50))
                                    }
                                    .buttonStyle(USPressStyle())
                                }
                                .padding(.vertical, 3)
                            }

                            if recommendations.isEmpty {
                                Text("No more suggestions here right now.")
                                    .font(.caption)
                                    .foregroundStyle(USTheme.tertiary)
                                    .padding(.vertical, 6)
                            }

                            BrandFooter().padding(.top, 10)
                            Color.clear.frame(height: 1).id(recommendationBottomID)
                        }
                        .padding(18)
                        .padding(.bottom, 50)
                    }
                    .onChange(of: tracks.count) { oldCount, newCount in
                        guard keepBottomAfterAdd, newCount > oldCount else { return }
                        DispatchQueue.main.async {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(recommendationBottomID, anchor: .bottom)
                            }
                            keepBottomAfterAdd = false
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        player.stopPreview()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { player.stopPreview() }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(USTheme.secondary)
            TextField("Search in \(playlist.title)", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(USTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)
    }

    private func playlistTrackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Button { player.play(track, queue: tracks) } label: {
                HStack(spacing: 11) {
                    PlaylistArtworkThumb(track: track, library: library, size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(USTheme.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(USPressStyle())

            if reorderMode {
                VStack(spacing: 1) {
                    Button { moveTrack(track.id, direction: -1) } label: {
                        Image(systemName: "chevron.up").frame(width: 28, height: 24)
                    }
                    Button { moveTrack(track.id, direction: 1) } label: {
                        Image(systemName: "chevron.down").frame(width: 28, height: 24)
                    }
                }
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.75))
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.20)) {
                        if playlist.title == "Liked Songs" { library.unlike(track.id) }
                        else { library.setTrack(track.id, inPlaylist: playlist.id, included: false) }
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.60))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(9)
        .background(Color.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.05)))
    }

    private func moveTrack(_ id: UUID, direction: Int) {
        let orderedIDs = tracks.map(\.id)
        guard let current = orderedIDs.firstIndex(of: id) else { return }
        let target = current + direction
        guard target >= 0, target < orderedIDs.count else { return }
        let otherID = orderedIDs[target]

        if playlist.title == "Liked Songs" {
            guard let first = library.tracks.firstIndex(where: { $0.id == id }),
                  let second = library.tracks.firstIndex(where: { $0.id == otherID }) else { return }
            library.tracks.swapAt(first, second)
            library.save()
        } else {
            guard let p = library.playlists.firstIndex(where: { $0.id == playlist.id }),
                  let first = library.playlists[p].trackIDs.firstIndex(of: id),
                  let second = library.playlists[p].trackIDs.firstIndex(of: otherID) else { return }
            library.playlists[p].trackIDs.swapAt(first, second)
            library.save()
        }
    }
}

private struct PlaylistArtworkThumb: View {
    let track: Track
    @ObservedObject var library: LibraryStore
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(USTheme.accent.opacity(0.10))

            if let localURL = library.customArtworkURL(for: track),
               let image = UIImage(contentsOfFile: localURL.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let raw = track.artworkURL, let url = URL(string: raw) {
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

struct ReplayCard: View {
    @ObservedObject var library: LibraryStore

    private var totalMinutes: Int {
        Int(library.stats.secondsByTrack.values.reduce(0, +) / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("UnSound Replay").font(.title3.bold())
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(USTheme.tertiary)
            }
            HStack {
                stat("Minutes", "\(totalMinutes)")
                stat("Liked", "\(library.likedTracks.count)")
                stat("Tracks", "\(library.tracks.count)")
            }
            Text("Open your daily, weekly, monthly and yearly listening story.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [USTheme.accentDeep.opacity(0.55), Color.black.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.065)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(USTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
