import Foundation
import CryptoKit
import Combine

struct UnSoundCloudSong: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let fileExtension: String
    let artworkURL: String?
}

@MainActor
final class UnSoundCloudCoordinator: ObservableObject {
    @Published var status = "Ready"
    @Published var detail = "Upload or download your private UnSound audio library."
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published private(set) var cloudFileCount = 0
    @Published private(set) var availableSongs: [UnSoundCloudSong] = []
    @Published private(set) var duplicatePrompt: UnSoundCloudSong?
    @Published var endpointText: String
    @Published var cloudCode: String

    private weak var library: LibraryStore?
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    private var automaticUploadTask: Task<Void, Never>?
    private var duplicateDecisionContinuation: CheckedContinuation<DuplicateDecision, Never>?
    private var skipRemainingDuplicates = false

    private enum DuplicateDecision {
        case skip
        case save
        case skipAll
    }

    private let endpointKey = "unsound.libraryCloud.endpoint"
    private let codeKey = "unsound.libraryCloud.code"

    private struct CloudManifest: Codable {
        var version = 1
        var updatedAt: Date
        var files: [CloudFile]
    }

    private struct CloudFile: Codable {
        var assetID: String
        var fileExtension: String
        var title: String
        var artist: String
        var source: String
        var sourceID: String?
        var artworkURL: String?
        var providerURL: String?
    }

    private struct LocalAsset {
        var track: Track
        var url: URL
        var assetID: String
        var fileExtension: String
    }

    init() {
        // One-time migration makes the new feature work immediately on the two
        // already-paired phones, but from this point on these settings are
        // completely independent from Shared Sync.
        let migratedEndpoint =
            defaults.string(forKey: endpointKey)
            ?? defaults.string(forKey: "unsound.cloud.endpoint")
            ?? "https://unsound-sync.adrian-tilg1.workers.dev"

        let migratedCode =
            defaults.string(forKey: codeKey)
            ?? defaults.string(forKey: "unsound.cloud.spaceCode")
            ?? ""

        endpointText = migratedEndpoint
        cloudCode = migratedCode

        if defaults.string(forKey: endpointKey) == nil {
            defaults.set(migratedEndpoint, forKey: endpointKey)
        }
        if defaults.string(forKey: codeKey) == nil, !migratedCode.isEmpty {
            defaults.set(migratedCode, forKey: codeKey)
        }
    }

    func attach(library: LibraryStore) {
        self.library = library
        cancellables.removeAll()

        // A newly imported local file is published automatically. Metadata-only
        // changes are ignored by reducing the stream to physical filenames.
        library.$tracks
            .map { tracks in tracks.compactMap(\.localFilename).sorted() }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleAutomaticUpload()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .unSoundConnectionChanged)
            .sink { [weak self] _ in
                self?.reloadConnection()
            }
            .store(in: &cancellables)

        if isConfigured {
            Task {
                await refresh()
                await uploadNow(automatic: true)
            }
        }
    }

    func reloadConnection() {
        endpointText = defaults.string(forKey: endpointKey) ?? endpointText
        cloudCode = defaults.string(forKey: codeKey) ?? cloudCode
        guard isConfigured else { return }
        Task {
            await refresh()
            await uploadNow(automatic: true)
        }
    }

    var isConfigured: Bool {
        normalizedEndpoint != nil && normalizedCode != nil
    }

    func saveConfiguration() {
        let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = cloudCode.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(endpoint, forKey: endpointKey)
        defaults.set(code, forKey: codeKey)
        status = isConfigured ? "Cloud connected" : "Enter cloud server + cloud key"
        if isConfigured {
            Task { await refresh() }
        }
    }

    func generateCloudCode() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        cloudCode = String((0..<20).compactMap { _ in alphabet.randomElement() })
        saveConfiguration()
    }

    func refresh() async {
        guard let endpoint = normalizedEndpoint, let code = normalizedCode else {
            cloudFileCount = 0
            status = "Cloud not configured"
            return
        }

        do {
            let manifest = try await fetchManifest(endpoint: endpoint, code: code)
            cloudFileCount = manifest?.files.count ?? 0
            availableSongs = (manifest?.files ?? []).map {
                UnSoundCloudSong(
                    id: $0.assetID,
                    title: $0.title,
                    artist: $0.artist,
                    fileExtension: $0.fileExtension,
                    artworkURL: $0.artworkURL
                )
            }
            if !isWorking {
                status = cloudFileCount == 0 ? "Cloud empty" : "CLOUD READY • \(cloudFileCount) files"
                detail = cloudFileCount == 0
                    ? "Imported songs upload automatically."
                    : "Songs are available even when the other iPhone is offline."
            }
        } catch {
            if !isWorking {
                status = "Cloud unavailable"
                detail = error.localizedDescription
            }
        }
    }

    func uploadNow(automatic: Bool = false) async {
        guard !isWorking else { return }
        guard let library, let endpoint = normalizedEndpoint, let code = normalizedCode else {
            status = "Cloud not configured"
            detail = "Open the setup section once and save the cloud server + key."
            return
        }

        isWorking = true
        progress = 0
        status = automatic ? "Checking new imports…" : "Scanning local audio…"
        detail = "Exact duplicate files are ignored."
        defer { isWorking = false }

        do {
            let localAssets = try await buildUniqueLocalAssets(library: library)
            guard !localAssets.isEmpty else {
                status = "Nothing to upload"
                detail = "No local audio files were found in UnSound."
                progress = 1
                return
            }

            var existing = try await fetchManifest(endpoint: endpoint, code: code)
                ?? CloudManifest(updatedAt: Date(), files: [])
            var byAssetID: [String: CloudFile] = [:]
            for item in existing.files {
                byAssetID[item.assetID] = item
            }

            var uploaded = 0
            var alreadyCloud = 0
            var failed = 0
            let total = max(1, localAssets.count)

            for (index, asset) in localAssets.enumerated() {
                status = "Uploading \(index + 1) / \(localAssets.count)"
                detail = asset.track.title

                do {
                    let exists = try await assetExists(
                        assetID: asset.assetID,
                        endpoint: endpoint,
                        code: code
                    )
                    if exists {
                        alreadyCloud += 1
                    } else {
                        try await uploadAsset(asset, endpoint: endpoint, code: code)
                        uploaded += 1
                    }

                    byAssetID[asset.assetID] = CloudFile(
                        assetID: asset.assetID,
                        fileExtension: asset.fileExtension,
                        title: asset.track.title,
                        artist: asset.track.artist,
                        source: asset.track.source,
                        sourceID: asset.track.sourceID,
                        artworkURL: asset.track.artworkURL,
                        providerURL: asset.track.providerURL
                    )
                } catch {
                    failed += 1
                }

                progress = Double(index + 1) / Double(total)
            }

            existing.updatedAt = Date()
            existing.files = Array(byAssetID.values).sorted {
                if $0.artist.caseInsensitiveCompare($1.artist) == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
            }

            let canonical = try await uploadManifest(existing, endpoint: endpoint, code: code)
            cloudFileCount = canonical.files.count
            availableSongs = canonical.files.map {
                UnSoundCloudSong(
                    id: $0.assetID,
                    title: $0.title,
                    artist: $0.artist,
                    fileExtension: $0.fileExtension,
                    artworkURL: $0.artworkURL
                )
            }
            progress = 1

            if failed == 0 {
                status = "CLOUD READY • \(cloudFileCount) files"
                detail = uploaded == 0
                    ? "Everything is already safely stored."
                    : "\(uploaded) uploaded automatically • \(alreadyCloud) already stored"
            } else {
                status = "Cloud ready with \(failed) failure\(failed == 1 ? "" : "s")"
                detail = "\(uploaded) uploaded • \(alreadyCloud) already stored • \(failed) failed"
            }
        } catch {
            status = "Upload failed"
            detail = error.localizedDescription
        }
    }

    func downloadNow() async {
        await downloadSongs(assetIDs: nil)
    }

    func downloadSelected(_ assetIDs: Set<String>) async {
        guard !assetIDs.isEmpty else { return }
        await downloadSongs(assetIDs: assetIDs)
    }

    func skipCurrentDuplicate() {
        resolveDuplicate(.skip)
    }

    func saveCurrentDuplicate() {
        resolveDuplicate(.save)
    }

    func skipAllCurrentDuplicates() {
        skipRemainingDuplicates = true
        resolveDuplicate(.skipAll)
    }

    private func downloadSongs(assetIDs: Set<String>?) async {
        guard !isWorking else { return }
        guard let library, let endpoint = normalizedEndpoint, let code = normalizedCode else {
            status = "Cloud not configured"
            detail = "Open the setup section once and save the cloud server + key."
            return
        }

        isWorking = true
        skipRemainingDuplicates = false
        progress = 0
        status = "Checking UnSound Cloud…"
        detail = "All missing files will download directly into UnSound."
        defer { isWorking = false }

        do {
            guard let manifest = try await fetchManifest(endpoint: endpoint, code: code),
                  !manifest.files.isEmpty else {
                cloudFileCount = 0
                status = "Cloud empty"
                detail = "The other phone needs to tap UPLOAD NOW first."
                progress = 1
                return
            }

            cloudFileCount = manifest.files.count
            availableSongs = manifest.files.map {
                UnSoundCloudSong(
                    id: $0.assetID,
                    title: $0.title,
                    artist: $0.artist,
                    fileExtension: $0.fileExtension,
                    artworkURL: $0.artworkURL
                )
            }
            let requestedFiles = assetIDs == nil
                ? manifest.files
                : manifest.files.filter { assetIDs!.contains($0.assetID) }
            var localHashes = try await localAssetIDs(library: library)
            var downloaded = 0
            var alreadyHere = 0
            var failed = 0
            let total = max(1, requestedFiles.count)

            for (index, item) in requestedFiles.enumerated() {
                status = "Downloading \(index + 1) / \(requestedFiles.count)"
                detail = item.title

                var forceDuplicateSave = false
                if localHashes.contains(item.assetID) {
                    if skipRemainingDuplicates {
                        alreadyHere += 1
                        progress = Double(index + 1) / Double(total)
                        continue
                    }

                    let decision = await requestDuplicateDecision(for: item)
                    switch decision {
                    case .skip, .skipAll:
                        alreadyHere += 1
                        progress = Double(index + 1) / Double(total)
                        continue
                    case .save:
                        forceDuplicateSave = true
                    }
                }

                do {
                    let temporaryURL = try await downloadAsset(
                        assetID: item.assetID,
                        endpoint: endpoint,
                        code: code
                    )
                    _ = try library.importCloudAudio(
                        from: temporaryURL,
                        title: item.title,
                        artist: item.artist,
                        source: item.source,
                        sourceID: forceDuplicateSave
                            ? "cloud-duplicate|\(item.assetID)|\(UUID().uuidString)"
                            : item.sourceID,
                        artworkURL: item.artworkURL,
                        providerURL: item.providerURL,
                        preferredExtension: item.fileExtension,
                        cloudAssetID: item.assetID
                    )
                    localHashes.insert(item.assetID)
                    downloaded += 1
                } catch {
                    failed += 1
                }

                progress = Double(index + 1) / Double(total)
            }

            progress = 1
            if failed == 0 {
                status = "DOWNLOAD COMPLETE"
                detail = "\(downloaded) downloaded • \(alreadyHere) already on this iPhone"
            } else {
                status = "Download finished with \(failed) failure\(failed == 1 ? "" : "s")"
                detail = "\(downloaded) downloaded • \(alreadyHere) already here • \(failed) failed"
            }
        } catch {
            status = "Download failed"
            detail = error.localizedDescription
        }
    }

    private func requestDuplicateDecision(for item: CloudFile) async -> DuplicateDecision {
        duplicatePrompt = UnSoundCloudSong(
            id: item.assetID,
            title: item.title,
            artist: item.artist,
            fileExtension: item.fileExtension,
            artworkURL: item.artworkURL
        )
        return await withCheckedContinuation { continuation in
            duplicateDecisionContinuation = continuation
        }
    }

    private func resolveDuplicate(_ decision: DuplicateDecision) {
        duplicatePrompt = nil
        let continuation = duplicateDecisionContinuation
        duplicateDecisionContinuation = nil
        continuation?.resume(returning: decision)
    }

    private func scheduleAutomaticUpload() {
        guard isConfigured else { return }
        automaticUploadTask?.cancel()
        automaticUploadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            // If a previous upload is still finishing, retain this import instead
            // of dropping its automatic upload event.
            while self?.isWorking == true && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            await self?.uploadNow(automatic: true)
        }
    }

    private func buildUniqueLocalAssets(library: LibraryStore) async throws -> [LocalAsset] {
        var result: [LocalAsset] = []
        var seen = Set<String>()

        for track in library.tracks {
            guard let url = library.localURL(for: track) else { continue }
            let info = try await hashInfo(for: url)
            guard seen.insert(info.assetID).inserted else { continue }
            result.append(
                LocalAsset(
                    track: track,
                    url: url,
                    assetID: info.assetID,
                    fileExtension: info.fileExtension
                )
            )
        }
        return result
    }

    private func localAssetIDs(library: LibraryStore) async throws -> Set<String> {
        var ids = Set<String>()
        for track in library.tracks {
            guard let url = library.localURL(for: track) else { continue }
            let info = try await hashInfo(for: url)
            ids.insert(info.assetID)
        }
        return ids
    }

    private func hashInfo(for url: URL) async throws -> (assetID: String, fileExtension: String) {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
                hasher.update(data: data)
            }

            let digest = hasher.finalize()
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let ext = Self.normalizedExtension(url.pathExtension)
            return (hash, ext)
        }.value
    }

    private func fetchManifest(endpoint: URL, code: String) async throws -> CloudManifest? {
        var request = URLRequest(url: endpoint.appendingPathComponent("cloud-library"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError(message: "No server response.")
        }
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw CloudError(message: "Server returned HTTP \(http.statusCode).")
        }
        if data.isEmpty || String(data: data, encoding: .utf8) == "null" { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudManifest.self, from: data)
    }

    private func uploadManifest(
        _ manifest: CloudManifest,
        endpoint: URL,
        code: String
    ) async throws -> CloudManifest {
        var request = URLRequest(url: endpoint.appendingPathComponent("cloud-library"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(manifest)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudError(message: "Could not save cloud library.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudManifest.self, from: data)
    }

    private func assetExists(assetID: String, endpoint: URL, code: String) async throws -> Bool {
        var request = URLRequest(url: cloudAssetURL(endpoint: endpoint, assetID: assetID))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { return false }
        guard (200...299).contains(http.statusCode) else {
            throw CloudError(message: "Cloud check failed (HTTP \(http.statusCode)).")
        }
        return true
    }

    private func uploadAsset(
        _ asset: LocalAsset,
        endpoint: URL,
        code: String
    ) async throws {
        var request = URLRequest(url: cloudAssetURL(endpoint: endpoint, assetID: asset.assetID))
        request.httpMethod = "PUT"
        request.timeoutInterval = 180
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        request.setValue(asset.fileExtension, forHTTPHeaderField: "X-UnSound-Extension")
        request.setValue(Self.contentType(for: asset.fileExtension), forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: asset.url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudError(message: "Audio upload failed.")
        }
    }

    private func downloadAsset(assetID: String, endpoint: URL, code: String) async throws -> URL {
        var request = URLRequest(url: cloudAssetURL(endpoint: endpoint, assetID: assetID))
        request.timeoutInterval = 180
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudError(message: "Audio download failed.")
        }
        return temporaryURL
    }

    private func cloudAssetURL(endpoint: URL, assetID: String) -> URL {
        endpoint
            .appendingPathComponent("cloud-audio")
            .appendingPathComponent(assetID)
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
        let raw = cloudCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.count >= 8 ? raw : nil
    }

    nonisolated private static func normalizedExtension(_ raw: String) -> String {
        let supported = Set(["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"])
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return supported.contains(cleaned) ? cleaned : "mp3"
    }

    nonisolated private static func contentType(for ext: String) -> String {
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

    private struct CloudError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
