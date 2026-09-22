import SwiftUI

private enum ManualLyricsMode: String, CaseIterable, Identifiable {
    case search = "SEARCH"
    case paste = "PASTE LRC"
    var id: String { rawValue }
}

struct ManualLyricsSearchView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ManualLyricsMode = .search
    @State private var title = ""
    @State private var artist = ""
    @State private var freeQuery = ""
    @State private var results: [LyricsService.ManualSearchResult] = []
    @State private var isSearching = false
    @State private var status: String?
    @State private var pastedLRC = ""

    private let service = LyricsService()

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    modePicker

                    if mode == .search {
                        searchPanel
                        resultsPanel
                    } else {
                        pastePanel
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let track = audio.currentTrack {
                title = service.cleanedLookupTitle(track.title)
                artist = track.artist
                freeQuery = [artist, title]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " ")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .black))
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true)
            }
            .buttonStyle(USPressStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text("FIND LYRICS")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                Text("Search manually inside UnSound or paste a synced LRC.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
            }
            Spacer()
        }
    }

    private var modePicker: some View {
        HStack(spacing: 5) {
            ForEach(ManualLyricsMode.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { mode = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == item ? Color.white.opacity(0.09) : Color.clear, in: Capsule())
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(5)
        .usGlass(Capsule(), interactive: true, tint: Color.black.opacity(0.18))
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANUAL MATCH")
                .font(.caption.bold())
                .tracking(1.4)
                .foregroundStyle(USTheme.tertiary)

            field("Song title", text: $title, icon: "music.note")
            field("Artist / rapper", text: $artist, icon: "person.fill")
            field("Free search", text: $freeQuery, icon: "magnifyingglass")

            Button {
                Task { await search() }
            } label: {
                HStack(spacing: 8) {
                    if isSearching {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(AppLocalization.text(isSearching ? "SEARCHING" : "SEARCH INSIDE UNSOUND"))
                }
                .font(.headline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(USPressStyle())
            .disabled(isSearching || (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && freeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

            if let status {
                Text(AppLocalization.text(status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(USTheme.secondary)
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 25, style: .continuous), tint: Color.white.opacity(0.01))
    }

    @ViewBuilder
    private var resultsPanel: some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("RESULTS")
                    .font(.caption.bold())
                    .tracking(1.4)
                    .foregroundStyle(USTheme.tertiary)

                ForEach(results) { result in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(USTheme.accent.opacity(0.10))
                                .frame(width: 48, height: 48)
                            Image(systemName: result.hasSyncedLyrics ? "quote.bubble.fill" : "text.alignleft")
                                .foregroundStyle(result.hasSyncedLyrics ? USTheme.accent : USTheme.secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(result.artist)
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)
                                .lineLimit(1)
                            if !result.album.isEmpty {
                                Text(result.album)
                                    .font(.caption2)
                                    .foregroundStyle(USTheme.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if result.hasSyncedLyrics {
                            Button("USE") {
                                Task { await use(result) }
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .usGlass(Capsule(), interactive: true, tint: USTheme.accent.opacity(0.14))
                            .buttonStyle(USPressStyle())
                        } else {
                            Text("NO SYNC")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(USTheme.tertiary)
                        }
                    }
                    .padding(11)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06)))
                }
            }
        }
    }

    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PASTE SYNCED LRC")
                .font(.caption.bold())
                .tracking(1.4)
                .foregroundStyle(USTheme.tertiary)

            Text("Paste timestamped LRC text here. Example format: [00:18.237] first lyric line. It stays stored inside UnSound for this song.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)

            TextEditor(text: $pastedLRC)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 260)
                .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.07)))

            Button {
                Task { await usePastedLRC() }
            } label: {
                Label("USE THIS LRC", systemImage: "checkmark.quote.bubble.fill")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(USPressStyle())
            .disabled(pastedLRC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let status {
                Text(AppLocalization.text(status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(USTheme.secondary)
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 25, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(USTheme.secondary)
                .frame(width: 18)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        status = nil
        do {
            results = try await service.manualSearch(title: title, artist: artist, freeQuery: freeQuery)
            status = results.isEmpty ? "No LRCLIB matches. You can still paste a synced LRC in the other tab." : "\(results.count) result\(results.count == 1 ? "" : "s") found."
        } catch {
            results = []
            status = "Search failed. Check the connection and try again."
        }
        isSearching = false
    }

    private func use(_ result: LyricsService.ManualSearchResult) async {
        guard let track = audio.currentTrack else { return }
        guard service.saveManualResult(result, forTitle: track.title, artist: track.artist) else {
            status = "That result has no synced timing."
            return
        }

        status = "Saved. Loading lyrics…"
        await player.retryLyricsLookup()
        if !player.lyrics.isEmpty { dismiss() }
    }

    private func usePastedLRC() async {
        guard let track = audio.currentTrack else { return }
        guard service.saveManualLRC(pastedLRC, title: track.title, artist: track.artist) else {
            status = "No valid [mm:ss.xxx] timestamps found in that text."
            return
        }

        status = "Saved. Loading lyrics…"
        await player.retryLyricsLookup()
        if !player.lyrics.isEmpty { dismiss() }
    }
}
