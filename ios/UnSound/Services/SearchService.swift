import Foundation
import AVFoundation

@MainActor
final class SearchService: ObservableObject {
    @Published var results: [ProviderSearchResult] = []
    @Published var message: String? = nil
    @Published var previewingResultID: String? = nil

    var youtubeAPIKey: String = UserDefaults.standard.string(forKey: "youtubeAPIKey") ?? ""

    private var previewPlayer: AVPlayer?
    private var previewTask: Task<Void, Never>?

    func search(query: String, source: SearchSource, category: SearchCategory, introMode: Bool = false) async {
        stopPreview()
        results = []
        message = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch source {
        case .audius:
            guard category == .all || category == .songs else {
                message = "Keyless Audius mode currently searches tracks."
                return
            }
            await searchAudius(query: trimmed, introMode: introMode)
        case .youtube:
            guard !youtubeAPIKey.isEmpty else {
                message = "Add a YouTube Data API key in Settings to enable live YouTube search. The Intro Hunt buttons still work without a key."
                return
            }
            await searchYouTube(query: trimmed, category: category)
        case .soundcloud:
            message = "SoundCloud's official API needs app credentials. Use Intro Hunt for keyless SoundCloud discovery."
        }
    }

    func toggleAudiusPreview(_ result: ProviderSearchResult, seconds: Double = 15) {
        guard result.source == .audius, result.isPreviewable else { return }

        if previewingResultID == result.id {
            stopPreview()
            return
        }

        stopPreview()

        var url = URL(string: "https://api.audius.co/v1/tracks")!
        url.appendPathComponent(result.id)
        url.appendPathComponent("stream")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "app_name", value: "UnSound")]

        let player = AVPlayer(url: components.url!)
        previewPlayer = player
        previewingResultID = result.id
        player.play()

        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(3, min(30, seconds)) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopPreview()
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.pause()
        previewPlayer = nil
        previewingResultID = nil
    }

    func downloadAudiusTrack(_ result: ProviderSearchResult) async throws -> (url: URL, filename: String) {
        guard result.source == .audius, result.isDownloadable else {
            throw NSError(
                domain: "UnSound.Search",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "This Audius track is not marked downloadable by its uploader."]
            )
        }

        var url = URL(string: "https://api.audius.co/v1/tracks")!
        url.appendPathComponent(result.id)
        url.appendPathComponent("download")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "original", value: "false")]

        let (temporaryURL, response) = try await URLSession.shared.download(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "UnSound.Search",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Audius download failed (HTTP \(http.statusCode))."]
            )
        }

        let suggested = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (suggested?.isEmpty == false ? suggested! : "\(result.title).mp3")
        return (temporaryURL, filename)
    }

    private func searchAudius(query: String, introMode: Bool) async {
        var queries = [query]
        if introMode {
            let lower = query.lowercased()
            let alreadyRare = ["intro", "extended", "edit", "unreleased", "fanmade", "fan made"].contains { lower.contains($0) }
            if !alreadyRare {
                queries.append(contentsOf: [
                    "\(query) intro",
                    "\(query) extended intro",
                    "\(query) fan edit",
                    "\(query) unreleased"
                ])
            }
        }

        do {
            var collected: [ProviderSearchResult] = []
            var seen = Set<String>()

            for term in queries {
                var components = URLComponents(string: "https://api.audius.co/v1/tracks/search")!
                components.queryItems = [
                    URLQueryItem(name: "query", value: term),
                    URLQueryItem(name: "limit", value: "20"),
                    URLQueryItem(name: "sort_method", value: "relevant")
                ]

                let (data, response) = try await URLSession.shared.data(from: components.url!)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continue
                }

                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = object?["data"] as? [[String: Any]] ?? []

                for row in rows {
                    guard let id = row["id"] as? String, !id.isEmpty, !seen.contains(id) else { continue }
                    seen.insert(id)

                    let title = row["title"] as? String ?? "Untitled"
                    let user = row["user"] as? [String: Any] ?? [:]
                    let artist = (user["name"] as? String) ?? (user["handle"] as? String) ?? "Audius"
                    let artwork = row["artwork"] as? [String: Any]
                    let artworkURL = (artwork?["480x480"] as? String) ?? (artwork?["150x150"] as? String)
                    let downloadable = row["is_downloadable"] as? Bool ?? false
                    let streamGated = row["is_stream_gated"] as? Bool ?? false

                    let handle = user["handle"] as? String
                    let permalink = row["permalink"] as? String
                    var providerURL: String? = nil
                    if let handle, let permalink, !handle.isEmpty, !permalink.isEmpty {
                        providerURL = "https://audius.co/\(handle)/\(permalink)"
                    }

                    var badges: [String] = ["Audius"]
                    if !streamGated { badges.append("Preview") }
                    if downloadable { badges.append("Importable") }
                    let subtitle = "\(artist) • \(badges.joined(separator: " • "))"

                    collected.append(
                        ProviderSearchResult(
                            id: id,
                            title: title,
                            subtitle: subtitle,
                            artworkURL: artworkURL,
                            durationText: nil,
                            kind: .songs,
                            source: .audius,
                            isDownloadable: downloadable,
                            isPreviewable: !streamGated,
                            providerURL: providerURL
                        )
                    )
                }
            }

            if introMode {
                collected.sort { lhs, rhs in
                    let lhsScore = rareScore(lhs.title) + rareScore(lhs.subtitle)
                    let rhsScore = rareScore(rhs.title) + rareScore(rhs.subtitle)
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    if lhs.isDownloadable != rhs.isDownloadable { return lhs.isDownloadable && !rhs.isDownloadable }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            } else {
                collected.sort { lhs, rhs in
                    if lhs.isDownloadable != rhs.isDownloadable { return lhs.isDownloadable && !rhs.isDownloadable }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }

            results = Array(collected.prefix(60))
            if results.isEmpty {
                message = introMode
                    ? "No Audius results found. Try the YouTube/SoundCloud Intro Hunt below for rarer edits."
                    : "No Audius results found."
            }
        } catch {
            message = "Audius search failed: \(error.localizedDescription)"
        }
    }

    private func rareScore(_ text: String) -> Int {
        let value = text.lowercased()
        var score = 0
        if value.contains("intro") { score += 5 }
        if value.contains("extended") { score += 4 }
        if value.contains("fan edit") || value.contains("fanmade") || value.contains("fan made") { score += 4 }
        if value.contains("unreleased") { score += 3 }
        if value.contains("edit") { score += 2 }
        return score
    }

    private func searchYouTube(query: String, category: SearchCategory) async {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var items = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "20"),
            URLQueryItem(name: "key", value: youtubeAPIKey)
        ]

        switch category {
        case .songs:
            items.append(URLQueryItem(name: "type", value: "video"))
        case .artists:
            items.append(URLQueryItem(name: "type", value: "channel"))
        case .playlists:
            items.append(URLQueryItem(name: "type", value: "playlist"))
        case .all:
            break
        }

        components.queryItems = items

        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "UnSound.Search",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "YouTube search failed (HTTP \(http.statusCode))."]
                )
            }

            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = object?["items"] as? [[String: Any]] ?? []

            results = rows.compactMap { row in
                let idObject = row["id"] as? [String: Any] ?? [:]
                let snippet = row["snippet"] as? [String: Any] ?? [:]
                let resultID = (idObject["videoId"] ?? idObject["channelId"] ?? idObject["playlistId"]) as? String ?? UUID().uuidString
                let title = snippet["title"] as? String ?? "Untitled"
                let channel = snippet["channelTitle"] as? String ?? "YouTube"
                let thumbnails = snippet["thumbnails"] as? [String: Any]
                let medium = thumbnails?["medium"] as? [String: Any]
                let thumbnail = medium?["url"] as? String

                let kind: SearchCategory
                let providerURL: String?
                if idObject["channelId"] != nil {
                    kind = .artists
                    providerURL = "https://www.youtube.com/channel/\(resultID)"
                } else if idObject["playlistId"] != nil {
                    kind = .playlists
                    providerURL = "https://www.youtube.com/playlist?list=\(resultID)"
                } else {
                    kind = .songs
                    providerURL = "https://www.youtube.com/watch?v=\(resultID)"
                }

                return ProviderSearchResult(
                    id: resultID,
                    title: title,
                    subtitle: channel,
                    artworkURL: thumbnail,
                    durationText: nil,
                    kind: kind,
                    source: .youtube,
                    isDownloadable: false,
                    isPreviewable: false,
                    providerURL: providerURL
                )
            }
        } catch {
            message = "Search failed: \(error.localizedDescription)"
        }
    }
}
