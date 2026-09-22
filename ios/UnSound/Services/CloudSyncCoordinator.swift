import Foundation
import UIKit
import CryptoKit

struct RemotePlaybackDisplay: Equatable {
    var deviceName: String
    var title: String
    var artist: String
    var artworkURL: String?
    var position: Double
    var duration: Double
    var isPlaying: Bool
    var sentAt: Date

    func estimatedPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(sentAt)) : 0
        return min(max(0, duration), max(0, position + elapsed))
    }
}

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    @Published var status = "Cloud sync off"
    @Published var isSyncing = false
    @Published var endpointText: String
    @Published var spaceCode: String
    @Published private(set) var lastSync: Date?
    @Published private(set) var inviteCode = ""
    @Published var joinCode = ""
    @Published private(set) var remotePlayback: RemotePlaybackDisplay?
    @Published private(set) var isListeningPartyHost = false
    @Published private(set) var isListeningPartyFollower = false

    @Published var shareAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shareAudioEnabled, forKey: "unsound.cloud.shareAudioEnabled")
        }
    }
    @Published private(set) var isTransferringAudio = false
    @Published private(set) var audioProgress: Double = 0
    @Published private(set) var audioStatus = "Audio transfer idle"
    @Published private(set) var availableAudioCount = 0
    @Published private(set) var lastDownloadedCount = 0
    @Published private(set) var lastSkippedCount = 0

    private weak var library: LibraryStore?
    private weak var player: PlayerCoordinator?
    private weak var audio: AudioEngine?
    private let lyricsService = LyricsService()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var playbackTimer: Timer?
    private var lastAppliedPlaybackSyncID: String?
    private var isApplyingPlayback = false
    private var partyID: String?
    private var partyStartedAt: Date?

    private static let defaultEndpoint = "https://unsound-sync.adrian-tilg1.workers.dev"

    private let assetCacheDefaultsKey = "unsound.cloud.audioAssetCache.v1"
    private let publishedAssetsDefaultsKey = "unsound.cloud.publishedAssetIDs.v1"
    private var assetCache: [String: CachedAsset] = [:]
    private var publishedAssetIDs: Set<String> = []
    private var remoteAssetByTrackKey: [String: RemoteAsset] = [:]

    private struct Snapshot: Codable {
        var schemaVersion = 3
        var deviceID: String
        var deviceName: String
        var updatedAt: Date
        var tracks: [CloudTrack]
        var playlists: [CloudPlaylist]
        var lyrics: [String: String]
        var playback: CloudPlayback? = nil
    }

    private struct CloudPlayback: Codable {
        var syncID: String
        var senderDeviceID: String
        var trackKey: String
        var position: Double
        var isPlaying: Bool
        var sentAt: Date
    }

    private struct PairInviteResponse: Codable {
        var code: String
        var expiresAt: Date
    }

    private struct PairJoinResponse: Codable {
        var token: String
    }

    private struct DevicePresence: Codable {
        var id: String
        var name: String
        var title: String?
        var artist: String?
        var artworkURL: String?
        var position: Double?
        var duration: Double?
        var isPlaying: Bool?
        var sentAt: Date?
        var lastSeen: Double?
    }

    private struct PartyState: Codable {
        var partyID: String
        var leaderDeviceID: String
        var leaderDeviceName: String
        var startedAt: Date
        var trackKey: String
        var title: String
        var artist: String
        var source: String
        var sourceID: String?
        var artworkURL: String?
        var providerURL: String?
        var assetID: String?
        var fileExtension: String?
        var position: Double
        var duration: Double
        var isPlaying: Bool
        var sentAt: Date
    }

    private struct CloudTrack: Codable {
        var key: String
        var title: String
        var artist: String
        var source: String
        var sourceID: String?
        var artworkURL: String?
        var providerURL: String?
        var isLiked: Bool
        var audioAssetID: String?
        var audioExtension: String?
    }

    private struct CloudPlaylist: Codable {
        var title: String
        var isPinned: Bool
        var trackKeys: [String]
    }

    private struct RemoteAsset: Sendable {
        var assetID: String
        var fileExtension: String
    }

    private struct CachedAsset: Codable, Sendable {
        var assetID: String
        var fileExtension: String
        var fileSize: Int64
        var modificationTime: TimeInterval
    }

    private struct TransferSummary {
        var uploaded = 0
        var alreadyRemote = 0
        var downloaded = 0
        var skippedExisting = 0
        var skippedDuplicate = 0
        var unavailable = 0
    }

    init() {
        endpointText = defaults.string(forKey: "unsound.cloud.endpoint") ?? Self.defaultEndpoint
        spaceCode =
            defaults.string(forKey: "unsound.cloud.spaceCode")
            ?? defaults.string(forKey: "unsound.libraryCloud.code")
            ?? ""
        lastSync = defaults.object(forKey: "unsound.cloud.lastSync") as? Date
        shareAudioEnabled = defaults.object(forKey: "unsound.cloud.shareAudioEnabled") as? Bool ?? false

        if let data = defaults.data(forKey: assetCacheDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: CachedAsset].self, from: data) {
            assetCache = decoded
        }
        publishedAssetIDs = Set(defaults.stringArray(forKey: publishedAssetsDefaultsKey) ?? [])
    }

    deinit {
        timer?.invalidate()
        playbackTimer?.invalidate()
    }

    func attach(
        library: LibraryStore,
        player: PlayerCoordinator? = nil,
        audio: AudioEngine? = nil
    ) {
        self.library = library
        if let player { self.player = player }
        if let audio { self.audio = audio }

        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isConfigured else { return }
                    await self.syncNow(silent: true)
                }
            }
        }

        if playbackTimer == nil {
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isConfigured else { return }
                    await self.refreshPresence()
                    if self.isListeningPartyHost {
                        await self.publishPartyState()
                    }
                    await self.pollParty()
                    await self.pollPlayback()
                }
            }
        }

        if isConfigured {
            Task {
                await refreshPresence()
                await pollParty()
            }
        }

    }

    var isConfigured: Bool {
        normalizedEndpoint != nil && normalizedCode != nil
    }

    func saveConfiguration() {
        let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = spaceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(endpoint, forKey: "unsound.cloud.endpoint")
        defaults.set(code, forKey: "unsound.cloud.spaceCode")
        status = isConfigured ? "Shared sync ready" : "Enter endpoint + sync code"
    }

    func generateSpaceCode() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        spaceCode = String((0..<16).compactMap { _ in alphabet.randomElement() })
        saveConfiguration()
    }

    func createConnectionCode() async {
        let token: String
        if let existing = normalizedCode {
            token = existing
        } else {
            token = Self.randomSecret(length: 32)
            applyConnectionToken(token)
        }

        guard let endpoint = normalizedEndpoint else {
            status = "Connection server unavailable"
            return
        }

        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("pair/invite"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let result = try JSONDecoder.unsoundCloud.decode(PairInviteResponse.self, from: data)
            inviteCode = result.code
            status = "Connection code ready"
        } catch {
            status = "Could not create code: \(error.localizedDescription)"
        }
    }

    func joinConnection() async {
        let clean = joinCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count >= 6, let endpoint = normalizedEndpoint else {
            status = "Enter the connection code"
            return
        }

        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("pair/join"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["code": clean])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let result = try JSONDecoder().decode(PairJoinResponse.self, from: data)
            applyConnectionToken(result.token)
            joinCode = ""
            status = "Connected"
            await refreshPresence()
        } catch {
            status = "Connection failed: \(error.localizedDescription)"
        }
    }

    func startListeningParty() async {
        guard isConfigured else {
            status = "Connect the two iPhones first"
            return
        }
        guard audio?.currentTrack != nil else {
            status = "Play a song before starting a Listening Party"
            return
        }
        partyID = UUID().uuidString
        partyStartedAt = Date()
        isListeningPartyHost = true
        isListeningPartyFollower = false
        await publishPartyState()
    }

    func leaveListeningParty() async {
        guard let endpoint = normalizedEndpoint, let code = normalizedCode else { return }
        isListeningPartyHost = false
        isListeningPartyFollower = false
        partyID = nil
        partyStartedAt = nil
        var request = URLRequest(url: endpoint.appendingPathComponent("party"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-UnSound-Device")
        _ = try? await URLSession.shared.data(for: request)
        status = "Listening Party ended"
    }

    func syncNow(silent: Bool = false) async {
        guard !isSyncing else { return }
        guard let library, let endpoint = normalizedEndpoint, let code = normalizedCode else {
            if !silent { status = "Configure shared sync first" }
            return
        }

        isSyncing = true
        if !silent { status = "Syncing shared space…" }
        defer { isSyncing = false }

        do {
            // The shared space carries song references/audio availability, not
            // personal likes or playlists. Those remain local to each iPhone.
            var remoteSnapshot: Snapshot?
            if let remote = try await fetchSnapshot(endpoint: endpoint, code: code) {
                remoteSnapshot = remote
                merge(remote, into: library)
            }

            // A manual SYNC NOW is a deliberate playback hand-off. Publish it
            // immediately so the other iPhone can jump to this song/position
            // without waiting for a potentially long audio batch upload.
            let outgoingPlayback = silent
                ? remoteSnapshot?.playback
                : (makePlaybackState() ?? remoteSnapshot?.playback)

            if !silent, let outgoingPlayback {
                let immediate = try await uploadSnapshot(
                    makeSnapshot(library: library, playback: outgoingPlayback),
                    endpoint: endpoint,
                    code: code
                )
                remoteSnapshot = immediate
                merge(immediate, into: library)
                status = "Playback sync sent"
            }

            let local = makeSnapshot(
                library: library,
                playback: outgoingPlayback ?? remoteSnapshot?.playback
            )
            let canonical = try await uploadSnapshot(local, endpoint: endpoint, code: code)
            merge(canonical, into: library)

            lastSync = Date()
            defaults.set(lastSync, forKey: "unsound.cloud.lastSync")
            if !silent {
                status = outgoingPlayback == nil
                    ? "Shared songs synced • \(library.tracks.count) tracks"
                    : "Playback + shared songs synced"
            }
        } catch {
            if !silent { status = "Cloud sync failed: \(error.localizedDescription)" }
        }
    }

    /// Uploads every local audio file that is not already present in the shared
    /// object store. Exact duplicate files use the same SHA-256 asset ID and are
    /// therefore uploaded only once even when several Track records point at
    /// equivalent audio.
    func publishAllLocalAudio() async {
        guard !isTransferringAudio else { return }
        guard let library, let endpoint = normalizedEndpoint, let code = normalizedCode else {
            audioStatus = "Configure Shared Sync first"
            return
        }

        isTransferringAudio = true
        audioProgress = 0
        lastDownloadedCount = 0
        lastSkippedCount = 0
        audioStatus = "Preparing local audio…"

        do {
            let summary = await publishLocalAudioAssets(
                library: library,
                endpoint: endpoint,
                code: code,
                updateProgress: true
            )

            // Publish the new asset IDs into the canonical metadata snapshot so
            // the other iPhone immediately knows which tracks are downloadable.
            var preservedPlayback: CloudPlayback?
            if let remote = try await fetchSnapshot(endpoint: endpoint, code: code) {
                preservedPlayback = remote.playback
                merge(remote, into: library)
            }
            let canonical = try await uploadSnapshot(
                makeSnapshot(library: library, playback: preservedPlayback),
                endpoint: endpoint,
                code: code
            )
            merge(canonical, into: library)

            audioProgress = 1
            let readyCount = summary.uploaded + summary.alreadyRemote
            if summary.unavailable == 0 {
                audioStatus = "CLOUD READY • all \(readyCount) local audio file\(readyCount == 1 ? "" : "s") shared"
            } else {
                audioStatus = "Cloud incomplete • \(readyCount) ready • \(summary.unavailable) failed"
            }
        } catch {
            audioStatus = "Audio upload failed: \(error.localizedDescription)"
        }

        isTransferringAudio = false
    }

    /// One-tap download for the second iPhone. Tracks that already have a local
    /// file are skipped. Exact duplicate files are identified by the same
    /// content hash and downloaded only once for the whole batch.
    func downloadAllAvailable() async {
        guard !isTransferringAudio else { return }
        guard let library, let endpoint = normalizedEndpoint, let code = normalizedCode else {
            audioStatus = "Configure Shared Sync first"
            return
        }

        isTransferringAudio = true
        audioProgress = 0
        lastDownloadedCount = 0
        lastSkippedCount = 0
        audioStatus = "Checking shared audio…"

        do {
            guard let remote = try await fetchSnapshot(endpoint: endpoint, code: code) else {
                availableAudioCount = 0
                audioStatus = "No shared songs available yet"
                isTransferringAudio = false
                return
            }

            merge(remote, into: library)
            let candidates = remote.tracks.filter { $0.audioAssetID != nil }
            availableAudioCount = Set(candidates.compactMap(\.audioAssetID)).count

            guard !candidates.isEmpty else {
                audioStatus = "No shared audio files published yet"
                isTransferringAudio = false
                return
            }

            // Build a hash set for files already present on this iPhone. Cached
            // hashes are instant; new local files are hashed once on a utility
            // thread so DOWNLOAD ALL never creates another physical duplicate.
            var knownLocalAssetIDs = Set<String>()
            var knownLocalURLByAssetID: [String: URL] = [:]
            let localTracks = library.tracks.compactMap { track -> (Track, URL)? in
                guard let url = library.localURL(for: track) else { return nil }
                return (track, url)
            }

            for pair in localTracks {
                let key = stableKey(for: pair.0)
                let info = try await resolvedAssetInfo(trackKey: key, url: pair.1)
                knownLocalAssetIDs.insert(info.assetID)
                if knownLocalURLByAssetID[info.assetID] == nil {
                    knownLocalURLByAssetID[info.assetID] = pair.1
                }
            }
            persistAssetCache()

            var summary = TransferSummary()
            var processed = 0
            let total = max(1, candidates.count)

            for remoteTrack in candidates {
                defer {
                    processed += 1
                    audioProgress = min(1, Double(processed) / Double(total))
                }

                guard let assetID = remoteTrack.audioAssetID else { continue }
                let ext = normalizedAudioExtension(remoteTrack.audioExtension ?? "m4a")

                guard let localTrack = localTrack(forCloudKey: remoteTrack.key, in: library) else {
                    summary.unavailable += 1
                    continue
                }

                if library.localURL(for: localTrack) != nil {
                    summary.skippedExisting += 1
                    knownLocalAssetIDs.insert(assetID)
                    continue
                }

                if let existingURL = knownLocalURLByAssetID[assetID] {
                    do {
                        let updated = try library.attachSharedAudio(
                            to: localTrack.id,
                            from: existingURL,
                            preferredExtension: ext
                        )
                        if let localURL = library.localURL(for: updated) {
                            let cached = try await cachedAssetUsingKnownHash(
                                assetID: assetID,
                                fileExtension: ext,
                                url: localURL
                            )
                            assetCache[remoteTrack.key] = cached
                            knownLocalURLByAssetID[assetID] = localURL
                        }
                        publishedAssetIDs.insert(assetID)
                        remoteAssetByTrackKey[remoteTrack.key] = RemoteAsset(
                            assetID: assetID,
                            fileExtension: ext
                        )
                        summary.skippedDuplicate += 1
                    } catch {
                        summary.unavailable += 1
                    }
                    continue
                }

                audioStatus = "Downloading \(remoteTrack.title)…"

                do {
                    let temporaryURL = try await downloadAsset(
                        assetID: assetID,
                        endpoint: endpoint,
                        code: code
                    )
                    let updated = try library.attachSharedAudio(
                        to: localTrack.id,
                        from: temporaryURL,
                        preferredExtension: ext
                    )

                    if let localURL = library.localURL(for: updated) {
                        let cached = try await cachedAssetUsingKnownHash(
                            assetID: assetID,
                            fileExtension: ext,
                            url: localURL
                        )
                        assetCache[remoteTrack.key] = cached
                    }

                    publishedAssetIDs.insert(assetID)
                    remoteAssetByTrackKey[remoteTrack.key] = RemoteAsset(assetID: assetID, fileExtension: ext)
                    knownLocalAssetIDs.insert(assetID)
                    if let localURL = library.localURL(for: updated) {
                        knownLocalURLByAssetID[assetID] = localURL
                    }
                    summary.downloaded += 1
                } catch let error as HTTPError where error.code == 404 {
                    summary.unavailable += 1
                } catch {
                    summary.unavailable += 1
                }
            }

            persistAssetCache()
            persistPublishedAssets()
            lastDownloadedCount = summary.downloaded
            lastSkippedCount = summary.skippedExisting + summary.skippedDuplicate
            audioProgress = 1

            var parts = ["\(summary.downloaded) downloaded"]
            if summary.skippedExisting > 0 { parts.append("\(summary.skippedExisting) already on iPhone") }
            if summary.skippedDuplicate > 0 { parts.append("\(summary.skippedDuplicate) duplicates linked") }
            if summary.unavailable > 0 { parts.append("\(summary.unavailable) unavailable") }
            audioStatus = parts.joined(separator: " • ")
        } catch {
            audioStatus = "Download all failed: \(error.localizedDescription)"
        }

        isTransferringAudio = false
    }

    private var normalizedEndpoint: URL? {
        let raw = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        if url.path.hasSuffix("/") {
            url.deleteLastPathComponent()
        }
        return url
    }

    private var normalizedCode: String? {
        let raw = spaceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 8 else { return nil }
        return raw
    }

    private func makeSnapshot(library: LibraryStore, playback: CloudPlayback? = nil) -> Snapshot {
        let tracks = library.tracks.map { track in
            let key = stableKey(for: track)
            let cached = assetCache[key]
            let localPublished: RemoteAsset? = {
                guard library.localURL(for: track) != nil,
                      let cached,
                      publishedAssetIDs.contains(cached.assetID) else { return nil }
                return RemoteAsset(assetID: cached.assetID, fileExtension: cached.fileExtension)
            }()
            let asset = localPublished ?? remoteAssetByTrackKey[key]

            return CloudTrack(
                key: key,
                title: track.title,
                artist: track.artist,
                source: track.source,
                sourceID: track.sourceID,
                artworkURL: track.artworkURL,
                providerURL: track.providerURL,
                // Shared Sync is intentionally not a shared account. Likes
                // remain personal on each iPhone.
                isLiked: false,
                audioAssetID: nil,
                audioExtension: nil
            )
        }

        return Snapshot(
            deviceID: deviceID,
            deviceName: UIDevice.current.name,
            updatedAt: Date(),
            tracks: tracks,
            playlists: [],
            lyrics: lyricsService.exportManualLyrics(),
            playback: playback
        )
    }

    private func merge(_ snapshot: Snapshot, into library: LibraryStore) {
        var idByKey: [String: UUID] = [:]
        for track in library.tracks {
            let key = stableKey(for: track)
            if idByKey[key] == nil { idByKey[key] = track.id }
        }

        for remote in snapshot.tracks {
            if let assetID = remote.audioAssetID {
                let ext = normalizedAudioExtension(remote.audioExtension ?? "m4a")
                remoteAssetByTrackKey[remote.key] = RemoteAsset(assetID: assetID, fileExtension: ext)
                publishedAssetIDs.insert(assetID)
            }

            if let id = idByKey[remote.key], let index = library.tracks.firstIndex(where: { $0.id == id }) {
                // Never throw away a local filename. Cloud sync owns metadata;
                // shared audio is attached explicitly by DOWNLOAD ALL.
                library.tracks[index].title = remote.title
                library.tracks[index].artist = remote.artist
                library.tracks[index].artworkURL = remote.artworkURL ?? library.tracks[index].artworkURL
                library.tracks[index].providerURL = remote.providerURL ?? library.tracks[index].providerURL
            } else {
                let reference = Track(
                    title: remote.title,
                    artist: remote.artist,
                    source: remote.source,
                    sourceID: remote.sourceID,
                    localFilename: nil,
                    artworkURL: remote.artworkURL,
                    providerURL: remote.providerURL,
                    isLiked: false
                )
                library.tracks.append(reference)
                idByKey[remote.key] = reference.id
            }
        }

        lyricsService.importManualLyrics(snapshot.lyrics)
        availableAudioCount = Set(snapshot.tracks.compactMap(\.audioAssetID)).count
        persistPublishedAssets()
        library.save()
    }

    private func makePlaybackState() -> CloudPlayback? {
        guard let audio, let track = audio.currentTrack else { return nil }
        return CloudPlayback(
            syncID: UUID().uuidString,
            senderDeviceID: deviceID,
            trackKey: stableKey(for: track),
            position: max(0, audio.currentTime),
            isPlaying: audio.isPlaying,
            sentAt: Date()
        )
    }

    private func applyConnectionToken(_ token: String) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 8 else { return }
        spaceCode = clean
        endpointText = Self.defaultEndpoint
        defaults.set(Self.defaultEndpoint, forKey: "unsound.cloud.endpoint")
        defaults.set(clean, forKey: "unsound.cloud.spaceCode")
        defaults.set(Self.defaultEndpoint, forKey: "unsound.libraryCloud.endpoint")
        defaults.set(clean, forKey: "unsound.libraryCloud.code")
        NotificationCenter.default.post(name: .unSoundConnectionChanged, object: nil)
    }

    nonisolated private static func randomSecret(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private func refreshPresence() async {
        guard let endpoint = normalizedEndpoint, let code = normalizedCode else { return }

        let current = audio?.currentTrack
        let payload = DevicePresence(
            id: deviceID,
            name: UIDevice.current.name,
            title: current?.title,
            artist: current?.artist,
            artworkURL: current?.artworkURL,
            position: audio?.currentTime,
            duration: audio?.duration,
            isPlaying: audio?.isPlaying,
            sentAt: Date(),
            lastSeen: nil
        )

        do {
            var update = URLRequest(url: endpoint.appendingPathComponent("device"))
            update.httpMethod = "POST"
            update.timeoutInterval = 10
            update.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
            update.setValue("application/json", forHTTPHeaderField: "Content-Type")
            update.httpBody = try JSONEncoder.unsoundCloud.encode(payload)
            _ = try await URLSession.shared.data(for: update)

            var request = URLRequest(url: endpoint.appendingPathComponent("devices"))
            request.timeoutInterval = 10
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }

            let devices = try JSONDecoder.unsoundCloud.decode([DevicePresence].self, from: data)
            let cutoff = Date().addingTimeInterval(-20).timeIntervalSince1970 * 1000
            guard let other = devices
                .filter({ $0.id != deviceID && ($0.lastSeen ?? 0) >= cutoff })
                .max(by: { ($0.lastSeen ?? 0) < ($1.lastSeen ?? 0) }) else {
                remotePlayback = nil
                return
            }

            guard let title = other.title,
                  let sentAt = other.sentAt else {
                remotePlayback = nil
                return
            }

            remotePlayback = RemotePlaybackDisplay(
                deviceName: other.name,
                title: title,
                artist: other.artist ?? "Unknown Artist",
                artworkURL: other.artworkURL,
                position: other.position ?? 0,
                duration: other.duration ?? 0,
                isPlaying: other.isPlaying ?? false,
                sentAt: sentAt
            )
        } catch {
            // Presence is best effort and must never interrupt playback.
        }
    }

    private func publishPartyState() async {
        guard isListeningPartyHost,
              let partyID,
              let startedAt = partyStartedAt,
              let endpoint = normalizedEndpoint,
              let code = normalizedCode,
              let audio,
              let track = audio.currentTrack else { return }

        var assetID: String?
        var fileExtension: String?
        if let fileURL = library?.localURL(for: track),
           let info = try? await resolvedAssetInfo(trackKey: stableKey(for: track), url: fileURL) {
            assetID = info.assetID
            fileExtension = info.fileExtension
        }

        let state = PartyState(
            partyID: partyID,
            leaderDeviceID: deviceID,
            leaderDeviceName: UIDevice.current.name,
            startedAt: startedAt,
            trackKey: stableKey(for: track),
            title: track.title,
            artist: track.artist,
            source: track.source,
            sourceID: track.sourceID,
            artworkURL: track.artworkURL,
            providerURL: track.providerURL,
            assetID: assetID,
            fileExtension: fileExtension,
            position: max(0, audio.currentTime),
            duration: max(0, audio.duration),
            isPlaying: audio.isPlaying,
            sentAt: Date()
        )

        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("party"))
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.unsoundCloud.encode(state)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let canonical = try JSONDecoder.unsoundCloud.decode(PartyState.self, from: data)
            if canonical.leaderDeviceID != deviceID {
                isListeningPartyHost = false
                await applyPartyState(canonical)
            } else {
                status = "Listening Party live"
            }
        } catch {
            status = "Listening Party connection lost"
        }
    }

    private func pollParty() async {
        guard !isApplyingPlayback,
              let endpoint = normalizedEndpoint,
              let code = normalizedCode else { return }

        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("party"))
            request.timeoutInterval = 10
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  !data.isEmpty,
                  String(data: data, encoding: .utf8) != "null" else { return }
            let state = try JSONDecoder.unsoundCloud.decode(PartyState.self, from: data)
            guard Date().timeIntervalSince(state.sentAt) < 12 else { return }

            if state.leaderDeviceID == deviceID {
                if partyID == state.partyID { return }
                return
            }

            if isListeningPartyHost,
               let localStart = partyStartedAt,
               localStart >= state.startedAt {
                return
            }

            isListeningPartyHost = false
            isListeningPartyFollower = true
            partyID = state.partyID
            partyStartedAt = state.startedAt
            await applyPartyState(state)
        } catch {
            // Party polling is silent; the last valid state stays visible.
        }
    }

    private func applyPartyState(_ state: PartyState) async {
        guard let library, let player, let audio else { return }
        isApplyingPlayback = true
        defer { isApplyingPlayback = false }

        var target = localTrack(forCloudKey: state.trackKey, in: library)
        if target == nil {
            target = library.upsertProviderReference(
                title: state.title,
                artist: state.artist,
                source: state.source,
                sourceID: state.sourceID ?? "party|\(state.trackKey)",
                artworkURL: state.artworkURL,
                providerURL: state.providerURL
            )
        }

        if let currentTarget = target,
           library.localURL(for: currentTarget) == nil,
           let assetID = state.assetID,
           let endpoint = normalizedEndpoint,
           let code = normalizedCode {
            do {
                let temporaryURL = try await downloadCloudAsset(
                    assetID: assetID,
                    endpoint: endpoint,
                    code: code
                )
                target = try library.importCloudAudio(
                    from: temporaryURL,
                    title: state.title,
                    artist: state.artist,
                    source: state.source,
                    sourceID: state.sourceID ?? "party|\(state.trackKey)",
                    artworkURL: state.artworkURL,
                    providerURL: state.providerURL,
                    preferredExtension: state.fileExtension ?? "mp3",
                    cloudAssetID: assetID
                )
            } catch {
                status = "Listening Party • waiting for song download"
                return
            }
        }

        guard let playable = target, library.localURL(for: playable) != nil else {
            status = "Listening Party • song unavailable"
            return
        }

        let delay = state.isPlaying ? min(6, max(0, Date().timeIntervalSince(state.sentAt))) : 0
        let targetPosition = min(state.duration, max(0, state.position + delay))

        if audio.currentTrack?.id != playable.id {
            player.play(playable, queue: [playable])
            audio.seek(to: targetPosition)
        } else if abs(audio.currentTime - targetPosition) > 0.8 {
            audio.seek(to: targetPosition)
        }

        if state.isPlaying {
            if !audio.isPlaying { audio.play() }
        } else if audio.isPlaying {
            audio.pause()
        }
        status = "Listening with \(state.leaderDeviceName)"
    }

    private func downloadCloudAsset(assetID: String, endpoint: URL, code: String) async throws -> URL {
        var request = URLRequest(
            url: endpoint
                .appendingPathComponent("cloud-audio")
                .appendingPathComponent(assetID)
        )
        request.timeoutInterval = 180
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return temporaryURL
    }

    private func pollPlayback() async {
        guard !isApplyingPlayback,
              !isSyncing,
              !isListeningPartyHost,
              !isListeningPartyFollower,
              let library,
              let player,
              let audio,
              let endpoint = normalizedEndpoint,
              let code = normalizedCode else { return }

        do {
            guard let snapshot = try await fetchSnapshot(endpoint: endpoint, code: code),
                  let playback = snapshot.playback,
                  playback.senderDeviceID != deviceID,
                  playback.syncID != lastAppliedPlaybackSyncID else { return }

            // Do not resurrect an old session just because the app was reopened
            // much later.
            guard Date().timeIntervalSince(playback.sentAt) < 60 else {
                lastAppliedPlaybackSyncID = playback.syncID
                return
            }

            isApplyingPlayback = true
            defer { isApplyingPlayback = false }

            merge(snapshot, into: library)

            guard var target = localTrack(forCloudKey: playback.trackKey, in: library) else {
                lastAppliedPlaybackSyncID = playback.syncID
                return
            }

            if library.localURL(for: target) == nil,
               let cloudTrack = snapshot.tracks.first(where: { $0.key == playback.trackKey }),
               let assetID = cloudTrack.audioAssetID {
                do {
                    let ext = normalizedAudioExtension(cloudTrack.audioExtension ?? "m4a")
                    let temporaryURL = try await downloadAsset(
                        assetID: assetID,
                        endpoint: endpoint,
                        code: code
                    )
                    target = try library.attachSharedAudio(
                        to: target.id,
                        from: temporaryURL,
                        preferredExtension: ext
                    )
                    if let localURL = library.localURL(for: target) {
                        assetCache[playback.trackKey] = try await cachedAssetUsingKnownHash(
                            assetID: assetID,
                            fileExtension: ext,
                            url: localURL
                        )
                    }
                    publishedAssetIDs.insert(assetID)
                    remoteAssetByTrackKey[playback.trackKey] = RemoteAsset(
                        assetID: assetID,
                        fileExtension: ext
                    )
                    persistAssetCache()
                    persistPublishedAssets()
                } catch {
                    status = "Playback received • download this song first"
                }
            }

            guard library.localURL(for: target) != nil else {
                lastAppliedPlaybackSyncID = playback.syncID
                return
            }

            if audio.currentTrack?.id != target.id {
                player.play(target, queue: [target])
            }

            let networkCompensation = playback.isPlaying
                ? min(4.0, max(0, Date().timeIntervalSince(playback.sentAt)))
                : 0
            audio.seek(to: playback.position + networkCompensation)

            if playback.isPlaying {
                if !audio.isPlaying { audio.play() }
            } else if audio.isPlaying {
                audio.pause()
            }

            lastAppliedPlaybackSyncID = playback.syncID
            status = "Playback synced • \(target.title)"
        } catch {
            // Playback polling is deliberately silent. Manual SYNC NOW still
            // exposes network/server errors in the main status card.
        }
    }

    private func fetchSnapshot(endpoint: URL, code: String) async throws -> Snapshot? {
        var request = URLRequest(url: endpoint.appendingPathComponent("shared-sync"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard (200...299).contains(http.statusCode) else { throw HTTPError(code: http.statusCode) }
        if data.isEmpty || String(data: data, encoding: .utf8) == "null" { return nil }
        return try JSONDecoder.unsoundCloud.decode(Snapshot.self, from: data)
    }

    private func uploadSnapshot(_ snapshot: Snapshot, endpoint: URL, code: String) async throws -> Snapshot {
        var request = URLRequest(url: endpoint.appendingPathComponent("shared-sync"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.unsoundCloud.encode(snapshot)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder.unsoundCloud.decode(Snapshot.self, from: data)
    }

    private func publishLocalAudioAssets(
        library: LibraryStore,
        endpoint: URL,
        code: String,
        updateProgress: Bool
    ) async -> TransferSummary {
        let localTracks = library.tracks.compactMap { track -> (Track, URL)? in
            guard let url = library.localURL(for: track) else { return nil }
            return (track, url)
        }

        var summary = TransferSummary()
        let total = max(1, localTracks.count)

        for (index, pair) in localTracks.enumerated() {
            let track = pair.0
            let url = pair.1
            let key = stableKey(for: track)

            if updateProgress {
                audioStatus = "Sharing \(track.title)…"
                audioProgress = Double(index) / Double(total)
            }

            do {
                let info = try await resolvedAssetInfo(trackKey: key, url: url)
                let exists = try await assetExists(assetID: info.assetID, endpoint: endpoint, code: code)

                if exists {
                    summary.alreadyRemote += 1
                } else {
                    try await uploadAsset(info: info, fileURL: url, endpoint: endpoint, code: code)
                    summary.uploaded += 1
                }

                publishedAssetIDs.insert(info.assetID)
                remoteAssetByTrackKey[key] = RemoteAsset(
                    assetID: info.assetID,
                    fileExtension: info.fileExtension
                )
            } catch {
                // One corrupt/oversized/network-failed file must not prevent the
                // rest of the shared library from being published.
                summary.unavailable += 1
            }
        }

        persistAssetCache()
        persistPublishedAssets()
        if updateProgress { audioProgress = 1 }
        return summary
    }

    private func assetExists(assetID: String, endpoint: URL, code: String) async throws -> Bool {
        var request = URLRequest(url: audioAssetURL(endpoint: endpoint, assetID: assetID))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { return false }
        guard (200...299).contains(http.statusCode) else { throw HTTPError(code: http.statusCode) }
        return true
    }

    private func uploadAsset(
        info: CachedAsset,
        fileURL: URL,
        endpoint: URL,
        code: String
    ) async throws {
        var request = URLRequest(url: audioAssetURL(endpoint: endpoint, assetID: info.assetID))
        request.httpMethod = "PUT"
        request.timeoutInterval = 180
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.setValue(info.fileExtension, forHTTPHeaderField: "X-UnSound-Extension")
        request.setValue(contentType(for: info.fileExtension), forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private func downloadAsset(assetID: String, endpoint: URL, code: String) async throws -> URL {
        var request = URLRequest(url: audioAssetURL(endpoint: endpoint, assetID: assetID))
        request.timeoutInterval = 180
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HTTPError(code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return temporaryURL
    }

    private func audioAssetURL(endpoint: URL, assetID: String) -> URL {
        endpoint
            .appendingPathComponent("shared-audio")
            .appendingPathComponent(assetID)
    }

    private func localTrack(forCloudKey key: String, in library: LibraryStore) -> Track? {
        library.tracks.first { stableKey(for: $0) == key }
    }

    private func resolvedAssetInfo(trackKey: String, url: URL) async throws -> CachedAsset {
        let cached = assetCache[trackKey]
        let info = try await Task.detached(priority: .utility) {
            try Self.computeAssetInfo(url: url, cached: cached)
        }.value
        assetCache[trackKey] = info
        return info
    }

    private func cachedAssetUsingKnownHash(
        assetID: String,
        fileExtension: String,
        url: URL
    ) async throws -> CachedAsset {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return CachedAsset(
                assetID: assetID,
                fileExtension: fileExtension,
                fileSize: size,
                modificationTime: modified
            )
        }.value
    }

    nonisolated private static func computeAssetInfo(url: URL, cached: CachedAsset?) throws -> CachedAsset {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let ext = normalizedAudioExtensionStatic(url.pathExtension)

        if let cached,
           cached.fileSize == size,
           abs(cached.modificationTime - modified) < 0.001,
           cached.fileExtension == ext {
            return cached
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return CachedAsset(
            assetID: hash,
            fileExtension: ext,
            fileSize: size,
            modificationTime: modified
        )
    }

    private func stableKey(for track: Track) -> String {
        if let sourceID = track.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
            return "\(track.source.lowercased())|\(sourceID)"
        }
        return "meta|\(normalize(track.artist))|\(normalize(track.title))"
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func normalizedAudioExtension(_ raw: String) -> String {
        Self.normalizedAudioExtensionStatic(raw)
    }

    nonisolated private static func normalizedAudioExtensionStatic(_ raw: String) -> String {
        let supported = Set(["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"])
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return supported.contains(cleaned) ? cleaned : "m4a"
    }

    private func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "flac": return "audio/flac"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }

    private func persistAssetCache() {
        if let data = try? JSONEncoder().encode(assetCache) {
            defaults.set(data, forKey: assetCacheDefaultsKey)
        }
    }

    private func persistPublishedAssets() {
        defaults.set(Array(publishedAssetIDs).sorted(), forKey: publishedAssetsDefaultsKey)
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: "unsound.cloud.deviceID") { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: "unsound.cloud.deviceID")
        return value
    }

    private struct HTTPError: LocalizedError {
        let code: Int
        var errorDescription: String? {
            if code == 503 { return "shared audio storage is not configured on the sync server" }
            if code == 413 { return "audio file is too large for the sync server" }
            return "server returned HTTP \(code)"
        }
    }
}

private extension JSONEncoder {
    static var unsoundCloud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var unsoundCloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Notification.Name {
    static let unSoundConnectionChanged = Notification.Name("UnSoundConnectionChanged")
}
