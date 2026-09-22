import Foundation

private actor LibraryPersistenceWriter {
    private struct Snapshot: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var stats: ListeningStats
    }

    func write(
        tracks: [Track],
        playlists: [Playlist],
        stats: ListeningStats,
        directory: URL,
        stateURL: URL,
        backupURL: URL
    ) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(
                Snapshot(tracks: tracks, playlists: playlists, stats: stats)
            )

            if fileManager.fileExists(atPath: stateURL.path) {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
                try? fileManager.copyItem(at: stateURL, to: backupURL)
            }
            try data.write(to: stateURL, options: .atomic)
        } catch {
            print("UnSound save error:", error)
        }
    }
}

struct DuplicateImportRequest: Identifiable {
    let id: UUID
    let stagedURL: URL
    let displayName: String
    let source: String
    let fingerprint: String
    let existingTitle: String
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var stats = ListeningStats()
    @Published private(set) var hiddenSuggestionIDs: Set<UUID> = []
    @Published private(set) var duplicateImportQueue: [DuplicateImportRequest] = []

    private enum DuplicateBehavior {
        case queue
        case skip
        case allow
    }

    private let fileManager = FileManager.default
    private let persistenceWriter = LibraryPersistenceWriter()
    private var pendingSaveTask: Task<Void, Never>?
    private let hiddenSuggestionsKey = "unsound.hiddenSuggestionIDs"
    private let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"
    ]

    init() {
        load()
        loadHiddenSuggestions()
        prepareImportDropFolder()
        _ = scanImportDropFolder()
    }

    var likedTracks: [Track] { tracks.filter(\.isLiked) }
    var currentDuplicateImport: DuplicateImportRequest? { duplicateImportQueue.first }

    var importDropFolderURL: URL {
        documentsDirectory.appendingPathComponent("UnSound Imports", isDirectory: true)
    }

    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }

    func track(source: String, sourceID: String) -> Track? {
        tracks.first {
            $0.source.caseInsensitiveCompare(source) == .orderedSame && $0.sourceID == sourceID
        }
    }

    func localURL(for track: Track) -> URL? {
        guard let filename = track.localFilename else { return nil }
        let url = mediaDirectory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func importAudio(from sourceURL: URL) throws -> Track {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }

        let track = try importAudioFile(
            from: sourceURL,
            source: "local",
            saveAfter: false,
            duplicateBehavior: .queue
        )
        save()
        return track
    }

    func importAudioCollection(from rootURL: URL) throws -> [Track] {
        try importAudioCollection(from: rootURL, duplicateBehavior: .queue)
    }

    @discardableResult
    func scanImportDropFolder() -> [Track] {
        prepareImportDropFolder()
        return (try? importAudioCollection(from: importDropFolderURL, duplicateBehavior: .skip)) ?? []
    }

    @discardableResult
    func acceptCurrentDuplicate() -> Track? {
        guard let request = duplicateImportQueue.first else { return nil }

        do {
            let track = try storeAudioCopy(
                from: request.stagedURL,
                source: request.source,
                sourceID: request.fingerprint + "|duplicate|" + UUID().uuidString,
                displayName: request.displayName
            )
            finishDuplicateRequest(request)
            save()
            return track
        } catch {
            print("Duplicate import failed:", error)
            finishDuplicateRequest(request)
            return nil
        }
    }

    func denyCurrentDuplicate() {
        guard let request = duplicateImportQueue.first else { return }
        finishDuplicateRequest(request)
    }

    func importProviderAudio(
        from sourceURL: URL,
        title: String,
        artist: String,
        source: String,
        sourceID: String?,
        artworkURL: String?,
        providerURL: String? = nil,
        preferredExtension: String = "mp3"
    ) throws -> Track {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedExtension = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = !requestedExtension.isEmpty ? requestedExtension : (!sourceExtension.isEmpty ? sourceExtension : "mp3")
        let storedName = "\(UUID().uuidString).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(storedName)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: sourceURL, to: destination)

        if let sourceID,
           let existingIndex = tracks.firstIndex(where: {
               $0.source.caseInsensitiveCompare(source) == .orderedSame && $0.sourceID == sourceID
           }) {
            if let oldFilename = tracks[existingIndex].localFilename {
                let oldURL = mediaDirectory.appendingPathComponent(oldFilename)
                if oldURL != destination { try? fileManager.removeItem(at: oldURL) }
            }
            tracks[existingIndex].title = title
            tracks[existingIndex].artist = artist
            tracks[existingIndex].localFilename = storedName
            tracks[existingIndex].artworkURL = artworkURL
            tracks[existingIndex].providerURL = providerURL
            let updated = tracks[existingIndex]
            save()
            return updated
        }

        let track = Track(
            title: title,
            artist: artist,
            source: source,
            sourceID: sourceID,
            localFilename: storedName,
            artworkURL: artworkURL,
            providerURL: providerURL
        )
        tracks.insert(track, at: 0)
        save()
        return track
    }

    func importCloudAudio(
        from sourceURL: URL,
        title: String,
        artist: String,
        source: String,
        sourceID: String?,
        artworkURL: String?,
        providerURL: String?,
        preferredExtension: String,
        cloudAssetID: String
    ) throws -> Track {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        let requestedExtension = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = !requestedExtension.isEmpty ? requestedExtension : (!sourceExtension.isEmpty ? sourceExtension : "mp3")
        let storedName = "\(UUID().uuidString).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(storedName)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        if let sourceID,
           let existingIndex = tracks.firstIndex(where: {
               $0.source.caseInsensitiveCompare(source) == .orderedSame && $0.sourceID == sourceID
           }) {
            if let oldFilename = tracks[existingIndex].localFilename {
                let oldURL = mediaDirectory.appendingPathComponent(oldFilename)
                if oldURL != destination { try? fileManager.removeItem(at: oldURL) }
            }
            tracks[existingIndex].title = title
            tracks[existingIndex].artist = artist
            tracks[existingIndex].localFilename = storedName
            tracks[existingIndex].artworkURL = artworkURL ?? tracks[existingIndex].artworkURL
            tracks[existingIndex].providerURL = providerURL ?? tracks[existingIndex].providerURL
            let updated = tracks[existingIndex]
            save()
            return updated
        }

        let effectiveSourceID = sourceID ?? "cloud|\(cloudAssetID)"
        let track = Track(
            title: title,
            artist: artist,
            source: source,
            sourceID: effectiveSourceID,
            localFilename: storedName,
            artworkURL: artworkURL,
            providerURL: providerURL
        )
        tracks.insert(track, at: 0)
        save()
        return track
    }

    @discardableResult
    func upsertProviderReference(
        title: String,
        artist: String,
        source: String,
        sourceID: String,
        artworkURL: String?,
        providerURL: String?
    ) -> Track {
        if let index = tracks.firstIndex(where: {
            $0.source.caseInsensitiveCompare(source) == .orderedSame && $0.sourceID == sourceID
        }) {
            tracks[index].title = title
            tracks[index].artist = artist
            tracks[index].artworkURL = artworkURL ?? tracks[index].artworkURL
            tracks[index].providerURL = providerURL ?? tracks[index].providerURL
            let existing = tracks[index]
            save()
            return existing
        }

        let track = Track(
            title: title,
            artist: artist,
            source: source,
            sourceID: sourceID,
            localFilename: nil,
            artworkURL: artworkURL,
            providerURL: providerURL
        )
        tracks.insert(track, at: 0)
        save()
        return track
    }

    func toggleLike(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isLiked.toggle(); save()
    }

    func like(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isLiked = true; save()
    }

    func unlike(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isLiked = false; save()
    }

    func hideSuggestion(_ id: UUID) {
        hiddenSuggestionIDs.insert(id)
        persistHiddenSuggestions()
    }

    func isSuggestionHidden(_ id: UUID) -> Bool {
        hiddenSuggestionIDs.contains(id)
    }

    func restoreSuggestion(_ id: UUID) {
        hiddenSuggestionIDs.remove(id)
        persistHiddenSuggestions()
    }

    func renameTrack(_ id: UUID, title: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].title = title; save()
    }

    func updateIntroOffset(_ id: UUID, milliseconds: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].introOffsetMs = milliseconds; save()
    }

    func updatePresets(_ id: UUID, presets: [AudioPreset], selected: UUID?) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].presets = presets
        tracks[i].selectedPresetID = selected
        save()
    }

    func createPlaylist(title: String) {
        playlists.append(Playlist(title: title)); save()
    }

    func renamePlaylist(_ id: UUID, title: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].title = title; save()
    }

    func togglePinned(_ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].isPinned.toggle(); save()
    }

    func setTrack(_ trackID: UUID, inPlaylist playlistID: UUID, included: Bool) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { $0 == trackID }
        if included { playlists[i].trackIDs.append(trackID) }
        save()
    }

    func tracks(in playlist: Playlist) -> [Track] { playlist.trackIDs.compactMap(track) }

    func recordPlay(_ track: Track) {
        let key = track.id.uuidString
        stats.playsByTrack[key, default: 0] += 1
        save()
    }

    func recordListen(_ track: Track, seconds: Double, bassDB: Double) {
        let key = track.id.uuidString
        stats.secondsByTrack[key, default: 0] += seconds
        stats.bassSamples.append(bassDB)
        if stats.bassSamples.count > 2000 { stats.bassSamples.removeFirst(stats.bassSamples.count - 2000) }
        save()
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var mediaDirectory: URL {
        documentsDirectory.appendingPathComponent("Media", isDirectory: true)
    }

    private var duplicateStagingDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent("UnSoundDuplicateReview", isDirectory: true)
    }

    private var stateDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var stateURL: URL {
        stateDirectory.appendingPathComponent("unsound-state.json")
    }

    private var backupStateURL: URL {
        stateDirectory.appendingPathComponent("unsound-state.backup.json")
    }

    private struct State: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var stats: ListeningStats
    }

    func save() {
        let tracksSnapshot = tracks
        let playlistsSnapshot = playlists
        let statsSnapshot = stats
        let directory = stateDirectory
        let primary = stateURL
        let backup = backupStateURL
        let writer = persistenceWriter

        // Collapse quick sequences such as playlist reordering or repeated
        // tuning changes into one write, then encode and write off the UI actor.
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await writer.write(
                tracks: tracksSnapshot,
                playlists: playlistsSnapshot,
                stats: statsSnapshot,
                directory: directory,
                stateURL: primary,
                backupURL: backup
            )
        }
    }

    private func load() {
        if let state = decodeState(at: stateURL) {
            applyLoadedState(state)
            return
        }

        if let backup = decodeState(at: backupStateURL) {
            print("UnSound recovered library from backup state")
            applyLoadedState(backup)
            // Do not overwrite the backup before the recovered state is alive.
            try? JSONEncoder().encode(backup).write(to: stateURL, options: .atomic)
            return
        }

        // Preserve an unreadable primary file for manual recovery rather than
        // overwriting it with an empty state on the next save.
        if fileManager.fileExists(atPath: stateURL.path) {
            let corruptURL = stateDirectory.appendingPathComponent("unsound-state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: stateURL, to: corruptURL)
            print("UnSound state unreadable; preserved at", corruptURL.lastPathComponent)
        }

        tracks = []
        playlists = [Playlist(title: "Playlist 1"), Playlist(title: "Playlist 2")]
        stats = ListeningStats()
    }

    private func decodeState(at url: URL) -> State? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            print("UnSound state decode failed for \(url.lastPathComponent):", error)
            return nil
        }
    }

    private func applyLoadedState(_ state: State) {
        tracks = state.tracks
        playlists = state.playlists
        stats = state.stats
        migrateLegacyCleanBassPresets()
    }

    private func loadHiddenSuggestions() {
        let raw = UserDefaults.standard.stringArray(forKey: hiddenSuggestionsKey) ?? []
        hiddenSuggestionIDs = Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func persistHiddenSuggestions() {
        let raw = hiddenSuggestionIDs.map(\.uuidString).sorted()
        UserDefaults.standard.set(raw, forKey: hiddenSuggestionsKey)
    }

    private func prepareImportDropFolder() {
        do {
            try fileManager.createDirectory(at: importDropFolderURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: duplicateStagingDirectory, withIntermediateDirectories: true)
        } catch {
            print("UnSound import folder error:", error)
        }
    }

    private func importAudioCollection(
        from rootURL: URL,
        duplicateBehavior: DuplicateBehavior
    ) throws -> [Track] {
        let access = rootURL.startAccessingSecurityScopedResource()
        defer { if access { rootURL.stopAccessingSecurityScopedResource() } }

        var imported: [Track] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        if let values = try? rootURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true {
            if isSupportedAudio(rootURL),
               let track = try? importAudioFile(
                   from: rootURL,
                   source: "bulk",
                   saveAfter: false,
                   duplicateBehavior: duplicateBehavior
               ) {
                imported.append(track)
            }
        } else if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard isSupportedAudio(url) else { continue }
                guard !url.path.hasPrefix(mediaDirectory.path) else { continue }
                if let track = try? importAudioFile(
                    from: url,
                    source: "bulk",
                    saveAfter: false,
                    duplicateBehavior: duplicateBehavior
                ) {
                    imported.append(track)
                }
            }
        }

        if !imported.isEmpty { save() }
        return imported
    }

    private func isSupportedAudio(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private func importFingerprint(for url: URL) -> String {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.lastPathComponent.lowercased())|\(size)"
    }

    private func existingTrack(for fingerprint: String) -> Track? {
        tracks.first {
            guard localURL(for: $0) != nil, let sourceID = $0.sourceID else { return false }
            return sourceID == fingerprint || sourceID.hasPrefix(fingerprint + "|duplicate|")
        }
    }

    private func importAudioFile(
        from sourceURL: URL,
        source: String,
        saveAfter: Bool,
        duplicateBehavior: DuplicateBehavior
    ) throws -> Track {
        guard isSupportedAudio(sourceURL) else {
            throw NSError(
                domain: "UnSound.Library",
                code: 415,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported audio file: \(sourceURL.lastPathComponent)"]
            )
        }

        let fingerprint = importFingerprint(for: sourceURL)
        if let existing = existingTrack(for: fingerprint) {
            switch duplicateBehavior {
            case .queue:
                try stageDuplicate(
                    sourceURL,
                    source: source,
                    fingerprint: fingerprint,
                    existingTitle: existing.title
                )
                throw duplicateQueuedError(sourceURL.lastPathComponent)
            case .skip:
                throw duplicateQueuedError(sourceURL.lastPathComponent)
            case .allow:
                break
            }
        }

        let sourceID = duplicateBehavior == .allow
            ? fingerprint + "|duplicate|" + UUID().uuidString
            : fingerprint
        let track = try storeAudioCopy(
            from: sourceURL,
            source: source,
            sourceID: sourceID,
            displayName: sourceURL.lastPathComponent
        )
        if saveAfter { save() }
        return track
    }

    private func storeAudioCopy(
        from sourceURL: URL,
        source: String,
        sourceID: String,
        displayName: String
    ) throws -> Track {
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let storedName = "\(UUID().uuidString).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(storedName)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: sourceURL, to: destination)

        let rawName = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let pieces = rawName.components(separatedBy: " - ")
        let artist = pieces.count > 1 ? pieces.first! : "Unknown Artist"
        let title = pieces.count > 1 ? pieces.dropFirst().joined(separator: " - ") : rawName
        let track = Track(
            title: title,
            artist: artist,
            source: source,
            sourceID: sourceID,
            localFilename: storedName
        )
        tracks.insert(track, at: 0)
        return track
    }

    private func stageDuplicate(
        _ sourceURL: URL,
        source: String,
        fingerprint: String,
        existingTitle: String
    ) throws {
        try fileManager.createDirectory(at: duplicateStagingDirectory, withIntermediateDirectories: true)

        if duplicateImportQueue.contains(where: { $0.fingerprint == fingerprint && $0.displayName == sourceURL.lastPathComponent }) {
            return
        }

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let stagedURL = duplicateStagingDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try fileManager.copyItem(at: sourceURL, to: stagedURL)

        duplicateImportQueue.append(
            DuplicateImportRequest(
                id: UUID(),
                stagedURL: stagedURL,
                displayName: sourceURL.lastPathComponent,
                source: source,
                fingerprint: fingerprint,
                existingTitle: existingTitle
            )
        )
    }

    private func finishDuplicateRequest(_ request: DuplicateImportRequest) {
        duplicateImportQueue.removeAll { $0.id == request.id }
        try? fileManager.removeItem(at: request.stagedURL)
    }

    private func duplicateQueuedError(_ filename: String) -> NSError {
        NSError(
            domain: "UnSound.Library",
            code: 409,
            userInfo: [NSLocalizedDescriptionKey: "Duplicate waiting for confirmation: \(filename)"]
        )
    }

    private func migrateLegacyCleanBassPresets() {
        var changed = false

        for trackIndex in tracks.indices {
            for presetIndex in tracks[trackIndex].presets.indices {
                let name = tracks[trackIndex].presets[presetIndex].name.uppercased()
                if name == "NORMAL" || name == "CAR" || name == "808 MAX" {
                    if tracks[trackIndex].presets[presetIndex].distortion != 0 ||
                        tracks[trackIndex].presets[presetIndex].reverb != 0 {
                        tracks[trackIndex].presets[presetIndex].distortion = 0
                        tracks[trackIndex].presets[presetIndex].reverb = 0
                        changed = true
                    }
                }
            }
        }

        if changed { save() }
    }
}
