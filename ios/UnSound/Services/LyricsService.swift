import Foundation

final class LyricsService {
    struct LRCLibEntry: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var syncedLyrics: String?
        var plainLyrics: String?
    }

    struct ManualSearchResult: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let syncedLyrics: String?
        let plainLyrics: String?

        var hasSyncedLyrics: Bool {
            !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private let manualOverridesDefaultsKey = "unsound.manualLyricsOverrides.v1"

    func fetchLyrics(title: String, artist: String, introOffsetMs: Int) async throws -> [LyricLine] {
        let base = try await fetchBaseLyrics(title: title, artist: artist)
        return shifted(base, byMilliseconds: introOffsetMs)
    }

    /// Returns original timing. A manually chosen/pasted LRC is preferred for
    /// this exact track identity so the choice survives relaunches.
    func fetchBaseLyrics(title: String, artist: String) async throws -> [LyricLine] {
        if let manual = manualLRC(title: title, artist: artist) {
            let parsed = parseLRC(manual, offset: 0)
            if !parsed.isEmpty { return parsed }
        }

        let candidates = searchCandidates(title: title, artist: artist)
        var seen = Set<String>()

        for candidate in candidates {
            let artistValue = usefulArtist(candidate.artist) ? candidate.artist : nil
            let key = "structured|\(candidate.title.lowercased())|\((artistValue ?? "").lowercased())"
            guard seen.insert(key).inserted else { continue }

            let entries = try await searchEntries(trackName: candidate.title, artistName: artistValue, query: nil)
            if let lyrics = bestSyncedLyrics(
                in: entries,
                requestedTitle: candidate.title,
                requestedArtist: candidate.artist
            ) {
                let parsed = parseLRC(lyrics, offset: 0)
                if !parsed.isEmpty { return parsed }
            }
        }

        for query in broadQueries(title: title, artist: artist, candidates: candidates) {
            let key = "q|\(query.lowercased())"
            guard seen.insert(key).inserted else { continue }

            let entries = try await searchEntries(trackName: nil, artistName: nil, query: query)
            if let lyrics = bestSyncedLyrics(
                in: entries,
                requestedTitle: cleanSongTitle(title),
                requestedArtist: usefulArtist(artist) ? artist : inferredArtistAndTitle(from: title)?.artist ?? ""
            ) {
                let parsed = parseLRC(lyrics, offset: 0)
                if !parsed.isEmpty { return parsed }
            }
        }

        return []
    }

    /// Manual in-app search when automatic matching fails. The user can edit
    /// artist/title or enter a free query without leaving UnSound.
    func manualSearch(title: String, artist: String, freeQuery: String) async throws -> [ManualSearchResult] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = freeQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        var collected: [LRCLibEntry] = []
        if !cleanTitle.isEmpty {
            collected.append(contentsOf: try await searchEntries(
                trackName: cleanTitle,
                artistName: usefulArtist(cleanArtist) ? cleanArtist : nil,
                query: nil
            ))
        }

        let q = !cleanQuery.isEmpty
            ? cleanQuery
            : [cleanArtist, cleanTitle].filter { !$0.isEmpty }.joined(separator: " ")

        if !q.isEmpty {
            collected.append(contentsOf: try await searchEntries(trackName: nil, artistName: nil, query: q))
        }

        var seen = Set<String>()
        var output: [ManualSearchResult] = []

        for entry in collected {
            let title = (entry.trackName ?? "Unknown title").trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = (entry.artistName ?? "Unknown artist").trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (entry.albumName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())|\((entry.syncedLyrics ?? "").count)"
            guard seen.insert(key).inserted else { continue }

            output.append(
                ManualSearchResult(
                    id: key,
                    title: title,
                    artist: artist,
                    album: album,
                    syncedLyrics: entry.syncedLyrics,
                    plainLyrics: entry.plainLyrics
                )
            )
            if output.count >= 30 { break }
        }

        return output
    }

    func lines(from result: ManualSearchResult) -> [LyricLine] {
        guard let synced = result.syncedLyrics else { return [] }
        return parseLRC(synced, offset: 0)
    }

    func parseUserLRC(_ text: String) -> [LyricLine] {
        parseLRC(text, offset: 0)
    }

    @discardableResult
    func saveManualResult(_ result: ManualSearchResult, forTitle title: String, artist: String) -> Bool {
        guard let synced = result.syncedLyrics, !parseLRC(synced, offset: 0).isEmpty else { return false }
        saveManualLRC(synced, title: title, artist: artist)
        return true
    }

    @discardableResult
    func saveManualLRC(_ text: String, title: String, artist: String) -> Bool {
        guard !parseLRC(text, offset: 0).isEmpty else { return false }
        var dictionary = UserDefaults.standard.dictionary(forKey: manualOverridesDefaultsKey) as? [String: String] ?? [:]
        dictionary[manualKey(title: title, artist: artist)] = text
        UserDefaults.standard.set(dictionary, forKey: manualOverridesDefaultsKey)
        return true
    }

    func removeManualLyrics(title: String, artist: String) {
        var dictionary = UserDefaults.standard.dictionary(forKey: manualOverridesDefaultsKey) as? [String: String] ?? [:]
        dictionary.removeValue(forKey: manualKey(title: title, artist: artist))
        UserDefaults.standard.set(dictionary, forKey: manualOverridesDefaultsKey)
    }

    func shifted(_ lines: [LyricLine], byMilliseconds milliseconds: Int) -> [LyricLine] {
        let offset = Double(milliseconds) / 1000.0
        return lines.map { LyricLine(time: max(0, $0.time + offset), text: $0.text) }
    }

    func cleanedLookupTitle(_ title: String) -> String {
        cleanSongTitle(title)
    }

    private func manualLRC(title: String, artist: String) -> String? {
        let dictionary = UserDefaults.standard.dictionary(forKey: manualOverridesDefaultsKey) as? [String: String] ?? [:]
        return dictionary[manualKey(title: title, artist: artist)]
    }

    private func manualKey(title: String, artist: String) -> String {
        let raw = "\(artist)|\(title)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return raw.replacingOccurrences(of: #"[^a-z0-9|]+"#, with: "", options: .regularExpression)
    }

    private func searchEntries(trackName: String?, artistName: String?, query: String?) async throws -> [LRCLibEntry] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var items: [URLQueryItem] = []

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        } else if let trackName, !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "track_name", value: trackName))
            if let artistName, usefulArtist(artistName) {
                items.append(URLQueryItem(name: "artist_name", value: artistName.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        guard !items.isEmpty else { return [] }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "UnSound/1.4.4 (https://github.com/germandc113-ai/Unsoundoiy-klup)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([LRCLibEntry].self, from: data)
    }

    private func bestSyncedLyrics(
        in entries: [LRCLibEntry],
        requestedTitle: String,
        requestedArtist: String
    ) -> String? {
        let requestedTitleKey = normalizeForComparison(requestedTitle)
        let requestedArtistKey = normalizeArtistForComparison(requestedArtist)

        let ranked = entries.compactMap { entry -> (score: Int, lyrics: String)? in
            guard let synced = entry.syncedLyrics,
                  !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let entryTitle = cleanSongTitle(entry.trackName ?? "")
            let entryTitleKey = normalizeForComparison(entryTitle)
            guard !entryTitleKey.isEmpty else { return nil }

            var score = 0
            if entryTitleKey == requestedTitleKey {
                score += 120
            } else if !requestedTitleKey.isEmpty &&
                        (entryTitleKey.contains(requestedTitleKey) || requestedTitleKey.contains(entryTitleKey)) {
                score += 72
            } else {
                score += titleWordOverlapScore(entryTitle, requestedTitle)
            }

            if !requestedArtistKey.isEmpty {
                let entryArtistKey = normalizeArtistForComparison(entry.artistName ?? "")
                if entryArtistKey == requestedArtistKey {
                    score += 45
                } else if !entryArtistKey.isEmpty &&
                            (entryArtistKey.contains(requestedArtistKey) || requestedArtistKey.contains(entryArtistKey)) {
                    score += 25
                }
            }

            let rawTitle = (entry.trackName ?? "").lowercased()
            if rawTitle.contains("instrumental") || rawTitle.contains("karaoke") { score -= 60 }
            return (score, synced)
        }
        .sorted { $0.score > $1.score }

        guard let best = ranked.first else { return nil }
        if requestedTitleKey.isEmpty || best.score >= 35 { return best.lyrics }
        return nil
    }

    private func searchCandidates(title: String, artist: String) -> [(title: String, artist: String)] {
        let originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = cleanSongTitle(originalTitle)

        var values: [(title: String, artist: String)] = []
        func append(_ rawTitle: String, _ rawArtist: String) {
            let candidateTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateArtist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidateTitle.isEmpty else { return }
            if !values.contains(where: {
                $0.title.caseInsensitiveCompare(candidateTitle) == .orderedSame &&
                $0.artist.caseInsensitiveCompare(candidateArtist) == .orderedSame
            }) {
                values.append((candidateTitle, candidateArtist))
            }
        }

        append(originalTitle, originalArtist)
        append(cleanedTitle, originalArtist)

        if let inferred = inferredArtistAndTitle(from: originalTitle) {
            let chosenArtist = usefulArtist(originalArtist) ? originalArtist : inferred.artist
            append(cleanSongTitle(inferred.title), chosenArtist)
            append(inferred.title, chosenArtist)
        }

        if usefulArtist(originalArtist) {
            for separator in [" - ", " – ", " — "] {
                let prefix = originalArtist + separator
                if originalTitle.lowercased().hasPrefix(prefix.lowercased()) {
                    let index = originalTitle.index(originalTitle.startIndex, offsetBy: prefix.count)
                    append(cleanSongTitle(String(originalTitle[index...])), originalArtist)
                }
            }
        }
        return values
    }

    private func broadQueries(
        title: String,
        artist: String,
        candidates: [(title: String, artist: String)]
    ) -> [String] {
        var queries: [String] = []
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !queries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                queries.append(trimmed)
            }
        }

        let cleaned = cleanSongTitle(title)
        if usefulArtist(artist) { append("\(cleaned) \(artist)") }
        if let inferred = inferredArtistAndTitle(from: title) {
            append("\(cleanSongTitle(inferred.title)) \(inferred.artist)")
        }
        for candidate in candidates where usefulArtist(candidate.artist) {
            append("\(cleanSongTitle(candidate.title)) \(candidate.artist)")
        }
        append(cleaned)
        return queries
    }

    private func inferredArtistAndTitle(from raw: String) -> (artist: String, title: String)? {
        for separator in [" - ", " – ", " — "] {
            guard let range = raw.range(of: separator) else { continue }
            let left = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !left.isEmpty, !right.isEmpty, left.count <= 80 else { continue }
            return (left, right)
        }
        return nil
    }

    private func usefulArtist(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        return !["unknown", "unknown artist", "various artists", "n/a", "na"].contains(value)
    }

    private func cleanSongTitle(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\.(mp3|m4a|aac|wav|flac|aiff?|caf)$"#, with: "", options: [.regularExpression, .caseInsensitive])

        let bracketPattern = #"\s*[\(\[][^\)\]]*(extended|tour|intro|outro|edit|slowed|reverb|sped|speed|unreleased|remaster|instrumental|clean|explicit|official|lyrics?|visualizer|version|mix)[^\)\]]*[\)\]]"#
        value = replacingRegex(bracketPattern, in: value, with: "")

        let separatorSuffix = #"\s*(\||/|[-–—])\s*(extended\s+tour\s+intro|tour\s+intro|extended\s+intro|concert\s+intro|live\s+intro|intro\s+version|extended\s+version|tour\s+version|slowed(?:\s*&\s*reverb)?|sped\s+up|speed\s+up|edit|unreleased|official\s+audio|official\s+video|lyrics?|visualizer)\b.*$"#
        value = replacingRegex(separatorSuffix, in: value, with: "")

        let bareSuffix = #"\s+(extended\s+tour\s+intro|tour\s+intro|extended\s+intro|concert\s+intro|live\s+intro|intro\s+version|extended\s+version|tour\s+version|slowed(?:\s*&\s*reverb)?|sped\s+up|speed\s+up|unreleased|official\s+audio|official\s+video|lyrics?|visualizer|edit)\s*$"#
        var previous = ""
        while previous != value {
            previous = value
            value = replacingRegex(bareSuffix, in: value, with: "")
        }

        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|/-–—")))
    }

    private func replacingRegex(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private func normalizeForComparison(_ value: String) -> String {
        cleanSongTitle(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func normalizeArtistForComparison(_ value: String) -> String {
        guard usefulArtist(value) else { return "" }
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func titleWordOverlapScore(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(words(lhs))
        let right = Set(words(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let common = left.intersection(right).count
        let total = left.union(right).count
        guard total > 0 else { return 0 }
        return Int((Double(common) / Double(total) * 60).rounded())
    }

    private func words(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func parseLRC(_ text: String, offset: Double) -> [LyricLine] {
        text.split(separator: "\n").compactMap { row in
            let string = String(row)
            guard let close = string.firstIndex(of: "]"), string.first == "[" else { return nil }
            let stamp = String(string[string.index(after: string.startIndex)..<close])
            let lyric = String(string[string.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let parts = stamp.split(separator: ":")
            guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return LyricLine(time: max(0, minutes * 60 + seconds + offset), text: lyric)
        }
        .sorted { $0.time < $1.time }
    }
}
