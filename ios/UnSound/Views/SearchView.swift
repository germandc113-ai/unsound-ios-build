import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    @ObservedObject var search: SearchService
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerCoordinator
    @Environment(\.openURL) private var openURL

    @State private var query = ""
    @State private var source: SearchSource = .audius
    @State private var mode: SearchMode = .all
    @State private var importing = false
    @State private var importingFolder = false
    @State private var importingProviderID: String? = nil
    @State private var providerImportMessage: String? = nil
    @State private var libraryImportMessage: String? = nil
    @State private var liveSearchTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    @Namespace private var sourceBubble
    @Namespace private var modeBubble

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var localMatches: [Track] {
        guard !trimmedQuery.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery) ||
            $0.artist.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var providerQuery: String {
        guard !trimmedQuery.isEmpty else { return "" }
        guard !mode.suffix.isEmpty else { return trimmedQuery }
        return "\(trimmedQuery) \(mode.suffix)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()

                ScrollView {
                    LazyVStack(spacing: 15) {
                        header
                        searchField
                        sourcePicker
                        modePicker

                        if let libraryImportMessage {
                            statusPill(libraryImportMessage, icon: "tray.and.arrow.down.fill")
                        }

                        if let providerImportMessage {
                            statusPill(providerImportMessage, icon: "checkmark.circle.fill")
                        }

                        if let message = search.message {
                            statusPill(message, icon: "info.circle.fill")
                        }

                        if trimmedQuery.isEmpty {
                            emptyState
                        } else {
                            results
                        }

                        BrandFooter()
                            .padding(.top, 12)
                    }
                    .padding(.horizontal, 17)
                    .padding(.top, 77)
                    .padding(.bottom, 112)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    var added: [Track] = []
                    for url in urls {
                        if let track = try? library.importAudio(from: url) {
                            added.append(track)
                        }
                    }
                    libraryImportMessage = added.isEmpty
                        ? "No new audio"
                        : "\(added.count) track\(added.count == 1 ? "" : "s") imported · 808 ready"
                    if let first = added.first {
                        player.play(first, queue: added)
                    }
                case .failure(let error):
                    libraryImportMessage = "Import failed · \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $importingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let folder = urls.first else { return }
                    do {
                        let added = try library.importAudioCollection(from: folder)
                        libraryImportMessage = added.isEmpty
                            ? "Folder scanned · nothing new"
                            : "\(added.count) track\(added.count == 1 ? "" : "s") imported · 808 ready"
                    } catch {
                        libraryImportMessage = "Folder import failed · \(error.localizedDescription)"
                    }
                case .failure(let error):
                    libraryImportMessage = "Folder import failed · \(error.localizedDescription)"
                }
            }
            .onAppear {
                let added = library.scanImportDropFolder()
                if !added.isEmpty {
                    libraryImportMessage = "\(added.count) new track\(added.count == 1 ? "" : "s") auto-imported"
                }
            }
            .onChange(of: query) { _, _ in
                scheduleLiveSearch()
            }
            .onChange(of: source) { _, _ in
                scheduleLiveSearch(immediate: true)
            }
            .onChange(of: mode) { _, _ in
                scheduleLiveSearch(immediate: true)
            }
            .onDisappear {
                liveSearchTask?.cancel()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SEARCH")
                    .font(.system(size: 31, weight: .black))
                    .fontWidth(.condensed)
                    .italic()
                    .tracking(-1.0)

                Text("FIND / ADD / 808")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(2.0)
                    .foregroundStyle(USTheme.accent)
            }

            Spacer()

            Menu {
                Button {
                    importing = true
                } label: {
                    Label("Import files", systemImage: "doc.badge.plus")
                }

                Button {
                    importingFolder = true
                } label: {
                    Label("Import folder", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.08))
            }
            .buttonStyle(USPressStyle())
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(searchFocused ? .white : .white.opacity(0.58))

            TextField("Song, artist, intro, edit…", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .onSubmit {
                    performProviderSearch()
                    searchFocused = false
                }

            if !query.isEmpty {
                Button {
                    liveSearchTask?.cancel()
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        query = ""
                        search.results = []
                        search.message = nil
                        providerImportMessage = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
            }

            Button {
                performProviderSearch()
                searchFocused = false
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(USTheme.accent, in: Circle())
                    .shadow(color: USTheme.accent.opacity(0.35), radius: 10)
            }
            .buttonStyle(USPressStyle())
            .disabled(trimmedQuery.isEmpty)
            .opacity(trimmedQuery.isEmpty ? 0.38 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .usGlass(
            RoundedRectangle(cornerRadius: 24, style: .continuous),
            interactive: true,
            tint: searchFocused ? USTheme.accent.opacity(0.085) : Color.white.opacity(0.012)
        )
        .scaleEffect(searchFocused ? 1.008 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: searchFocused)
    }

    private var sourcePicker: some View {
        HStack(spacing: 7) {
            sourceChip(.audius, title: "IN APP", icon: "waveform")
            sourceChip(.youtube, title: "YT", icon: "play.rectangle.fill")
            sourceChip(.soundcloud, title: "SC", icon: "waveform.path")
        }
        .padding(5)
        .usGlass(Capsule(), interactive: true, tint: Color.black.opacity(0.18))
    }

    private func sourceChip(_ value: SearchSource, title: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
                source = value
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.7)
            }
            .foregroundStyle(source == value ? .white : .white.opacity(0.42))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if source == value {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .usGlass(Capsule(), tint: USTheme.accent.opacity(value == .audius ? 0.09 : 0.035))
                        .matchedGeometryEffect(id: "source", in: sourceBubble)
                }
            }
        }
        .buttonStyle(USPressStyle())
    }

    private var modePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchMode.allCases) { value in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                            mode = value
                        }
                    } label: {
                        Text(value.rawValue)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(mode == value ? .white : .white.opacity(0.42))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                if mode == value {
                                    Capsule()
                                        .fill(USTheme.accent.opacity(0.14))
                                        .usGlass(Capsule(), tint: USTheme.accent.opacity(0.10))
                                        .matchedGeometryEffect(id: "mode", in: modeBubble)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.025))
                                }
                            }
                    }
                    .buttonStyle(USPressStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var results: some View {
        if !localMatches.isEmpty {
            resultSectionTitle("YOUR AUDIO", count: localMatches.count)
            VStack(spacing: 7) {
                ForEach(localMatches) { track in
                    localTrackRow(track)
                }
            }
        }

        if !search.results.isEmpty {
            resultSectionTitle(source == .audius ? "ONLINE" : source.rawValue.uppercased(), count: search.results.count)
            VStack(spacing: 8) {
                ForEach(search.results) { result in
                    providerResultRow(result)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: search.results)
        }

        if localMatches.isEmpty && search.results.isEmpty && search.message == nil && supportsLiveProviderSearch {
            VStack(spacing: 10) {
                ProgressView().tint(USTheme.accent)
                Text("SEARCHING")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(USTheme.tertiary)
            }
            .padding(.top, 30)
        }

        if source != .audius {
            externalFallback
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.025))
                    .frame(width: 122, height: 122)
                    .usGlass(Circle(), tint: USTheme.accent.opacity(0.05))

                Circle()
                    .stroke(USTheme.accent.opacity(0.32), lineWidth: 5)
                    .frame(width: 74, height: 74)
                    .blur(radius: 2)

                VStack(spacing: 0) {
                    Text("808")
                        .font(.system(size: 26, weight: .black, design: .rounded))
                    Text("READY")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(2.1)
                        .foregroundStyle(USTheme.accent)
                }
            }

            Text("SEARCH YOUR VERSION")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(1.7)

            HStack(spacing: 10) {
                quickImportButton("FILES", icon: "doc.badge.plus") { importing = true }
                quickImportButton("FOLDER", icon: "folder.badge.plus") { importingFolder = true }
            }
        }
        .padding(.top, 34)
    }

    private func quickImportButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 10, weight: .black, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)
        }
        .buttonStyle(USPressStyle())
    }

    private func localTrackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Button {
                player.play(track, queue: localMatches)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [USTheme.accent.opacity(0.18), Color.white.opacity(0.025)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .overlay(
                            Image(systemName: "waveform")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(USTheme.accent)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(track.artist).lineLimit(1)
                            Text("808 READY")
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(USTheme.accent)
                        }
                        .font(.caption)
                        .foregroundStyle(USTheme.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(USPressStyle())

            playlistMenu(for: track)
        }
        .padding(10)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(USTheme.hairline))
    }

    private func playlistMenu(for track: Track) -> some View {
        Menu {
            if library.playlists.isEmpty {
                Button("Create a playlist first") { }.disabled(true)
            } else {
                ForEach(library.playlists) { playlist in
                    Button {
                        library.setTrack(track.id, inPlaylist: playlist.id, included: true)
                        providerImportMessage = "\(track.title) → \(playlist.title)"
                    } label: {
                        Label(playlist.title, systemImage: playlist.trackIDs.contains(track.id) ? "checkmark" : "plus")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 39, height: 39)
                .contentShape(Circle())
                .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.11))
        }
        .buttonStyle(.plain)
    }

    private func providerResultRow(_ result: ProviderSearchResult) -> some View {
        HStack(spacing: 11) {
            AsyncImage(url: result.artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.black
                    Image(systemName: providerIcon(result.source))
                        .foregroundStyle(USTheme.accent.opacity(0.85))
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    sourceBadge(result.source)
                    if result.source == .audius && result.isDownloadable {
                        Text("808 READY").foregroundStyle(USTheme.accent)
                    } else if result.source == .audius && result.isPreviewable {
                        Text("PREVIEW").foregroundStyle(.white.opacity(0.52))
                    }
                }
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.65)
            }

            Spacer(minLength: 2)

            if result.source == .audius && result.isPreviewable {
                Button {
                    search.toggleAudiusPreview(result)
                } label: {
                    Image(systemName: search.previewingResultID == result.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 37, height: 37)
                        .usGlass(Circle(), interactive: true)
                }
                .buttonStyle(USPressStyle())
            }

            if result.source == .audius && result.isDownloadable {
                Menu {
                    Button("Add to UnSound") {
                        importAudius(result)
                    }

                    if !library.playlists.isEmpty {
                        Divider()
                        ForEach(library.playlists) { playlist in
                            Button {
                                importAudius(result, playlistID: playlist.id)
                            } label: {
                                Label(playlist.title, systemImage: "plus")
                            }
                        }
                    }
                } label: {
                    if importingProviderID == result.id {
                        ProgressView().tint(.white).frame(width: 39, height: 39)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 39, height: 39)
                            .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.13))
                    }
                }
                .buttonStyle(.plain)
                .disabled(importingProviderID != nil)
            } else if let providerURL = result.providerURL, let url = URL(string: providerURL) {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 37, height: 37)
                        .usGlass(Circle(), interactive: true)
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(USTheme.hairline))
    }

    private var externalFallback: some View {
        HStack(spacing: 9) {
            Button {
                openExternal(provider: .youtube, suffix: mode.suffix)
            } label: {
                Label("OPEN YT", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
            }

            Button {
                openExternal(provider: .soundcloud, suffix: mode.suffix)
            } label: {
                Label("OPEN SC", systemImage: "waveform.path").frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 9, weight: .black, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(.white)
        .padding(.top, 3)
        .buttonStyle(USPressStyle())
        .labelStyle(.titleAndIcon)
    }

    private func resultSectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.7)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(USTheme.tertiary)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.top, 4)
    }

    private func statusPill(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(USTheme.accent)
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(USTheme.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .usGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private func sourceBadge(_ value: SearchSource) -> some View {
        Text(value == .audius ? "IN APP" : value.rawValue.uppercased())
            .foregroundStyle(.white.opacity(0.48))
    }

    private func providerIcon(_ value: SearchSource) -> String {
        switch value {
        case .audius: return "waveform"
        case .youtube: return "play.rectangle.fill"
        case .soundcloud: return "waveform.path"
        }
    }

    private var supportsLiveProviderSearch: Bool {
        source == .audius || (source == .youtube && !search.youtubeAPIKey.isEmpty)
    }

    private func scheduleLiveSearch(immediate: Bool = false) {
        liveSearchTask?.cancel()

        guard !trimmedQuery.isEmpty else {
            search.results = []
            search.message = nil
            return
        }

        guard supportsLiveProviderSearch else {
            search.results = []
            search.message = nil
            return
        }

        let liveQuery = providerQuery
        let liveSource = source
        let liveMode = mode

        liveSearchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 280_000_000)
            }
            guard !Task.isCancelled else { return }

            await search.search(
                query: liveQuery,
                source: liveSource,
                category: .songs,
                introMode: liveSource == .audius && liveMode == .all
            )
        }
    }

    private func performProviderSearch() {
        guard !trimmedQuery.isEmpty else { return }
        liveSearchTask?.cancel()
        providerImportMessage = nil
        search.message = nil

        if source == .soundcloud {
            openExternal(provider: .soundcloud, suffix: mode.suffix)
            return
        }

        if source == .youtube && search.youtubeAPIKey.isEmpty {
            openExternal(provider: .youtube, suffix: mode.suffix)
            return
        }

        Task {
            await search.search(
                query: providerQuery,
                source: source,
                category: .songs,
                introMode: source == .audius && mode == .all
            )
        }
    }

    private func importAudius(_ result: ProviderSearchResult, playlistID: UUID? = nil) {
        guard importingProviderID == nil else { return }

        if let existing = library.track(source: "audius", sourceID: result.id),
           library.localURL(for: existing) != nil {
            if let playlistID {
                library.setTrack(existing.id, inPlaylist: playlistID, included: true)
                let playlistName = library.playlists.first(where: { $0.id == playlistID })?.title ?? "playlist"
                providerImportMessage = "\(existing.title) → \(playlistName)"
            } else {
                player.play(existing, queue: [existing])
            }
            return
        }

        importingProviderID = result.id
        providerImportMessage = "Adding \(result.title)…"
        search.stopPreview()

        Task {
            do {
                let download = try await search.downloadAudiusTrack(result)
                let ext = URL(fileURLWithPath: download.filename).pathExtension
                let artist = result.subtitle.components(separatedBy: " • ").first ?? "Audius"
                let track = try library.importProviderAudio(
                    from: download.url,
                    title: result.title,
                    artist: artist,
                    source: "audius",
                    sourceID: result.id,
                    artworkURL: result.artworkURL,
                    providerURL: result.providerURL,
                    preferredExtension: ext.isEmpty ? "mp3" : ext
                )

                if let playlistID {
                    library.setTrack(track.id, inPlaylist: playlistID, included: true)
                    let playlistName = library.playlists.first(where: { $0.id == playlistID })?.title ?? "playlist"
                    providerImportMessage = "\(track.title) → \(playlistName) · 808 ready"
                } else {
                    providerImportMessage = "\(track.title) added · 808 ready"
                    player.play(track, queue: [track])
                }
            } catch {
                providerImportMessage = "Add failed · \(error.localizedDescription)"
            }
            importingProviderID = nil
        }
    }

    private func openExternal(provider: ExternalProvider, suffix: String) {
        let suffixPart = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = suffixPart.isEmpty ? trimmedQuery : "\(trimmedQuery) \(suffixPart)"
        var components: URLComponents

        switch provider {
        case .youtube:
            components = URLComponents(string: "https://www.youtube.com/results")!
            components.queryItems = [URLQueryItem(name: "search_query", value: term)]
        case .soundcloud:
            components = URLComponents(string: "https://soundcloud.com/search/sounds")!
            components.queryItems = [URLQueryItem(name: "q", value: term)]
        }

        if let url = components.url {
            openURL(url)
        }
    }
}

private enum SearchMode: String, CaseIterable, Identifiable {
    case all = "ALL"
    case intro = "INTRO"
    case extended = "EXTENDED"
    case unreleased = "UNRELEASED"
    case edit = "EDIT"

    var id: String { rawValue }

    var suffix: String {
        switch self {
        case .all: return ""
        case .intro: return "intro"
        case .extended: return "extended intro"
        case .unreleased: return "unreleased"
        case .edit: return "fan edit"
        }
    }
}

private enum ExternalProvider {
    case youtube
    case soundcloud
}
