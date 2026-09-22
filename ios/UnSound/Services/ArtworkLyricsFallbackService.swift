import Foundation
import UIKit
import Vision

final class ArtworkLyricsFallbackService {
    private struct LRCLibEntry: Decodable {
        var trackName: String?
        var artistName: String?
        var syncedLyrics: String?
    }

    func recognizeText(in imageData: Data) async -> [String] {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]

                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                    let values = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .flatMap { self.cleanedTokens(from: $0) }

                    var seen = Set<String>()
                    let unique = values.filter { token in
                        let key = token.lowercased()
                        return token.count >= 2 && seen.insert(key).inserted
                    }
                    continuation.resume(returning: Array(unique.prefix(12)))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func fetchSyncedLyrics(title: String, artist: String, artworkWords: [String]) async throws -> [LyricLine] {
        let cleanTitle = cleanedTitle(title)
        let usefulWords = artworkWords
            .filter { !$0.localizedCaseInsensitiveContains("explicit") }
            .prefix(10)

        var queries: [String] = []
        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !queries.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                queries.append(value)
            }
        }

        if usefulArtist(artist) {
            add("\(cleanTitle) \(artist)")
        }

        let coverText = usefulWords.joined(separator: " ")
        if !coverText.isEmpty {
            add("\(cleanTitle) \(coverText)")
            add(coverText)
        }
        add(cleanTitle)

        let requestedTitleKey = normalized(cleanTitle)
        let requestedArtistKey = usefulArtist(artist) ? normalized(artist) : ""
        let coverKey = normalized(coverText)

        var best: (score: Int, lyrics: String)?

        for query in queries.prefix(4) {
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("UnSound/1.4.3 artwork-ocr", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
            let entries = try JSONDecoder().decode([LRCLibEntry].self, from: data)

            for entry in entries {
                guard let synced = entry.syncedLyrics,
                      !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let entryTitle = cleanedTitle(entry.trackName ?? "")
                let entryTitleKey = normalized(entryTitle)
                guard !entryTitleKey.isEmpty else { continue }

                var score = 0
                if entryTitleKey == requestedTitleKey {
                    score += 140
                } else if !requestedTitleKey.isEmpty &&
                            (entryTitleKey.contains(requestedTitleKey) || requestedTitleKey.contains(entryTitleKey)) {
                    score += 80
                } else {
                    score += overlapScore(entryTitle, cleanTitle)
                }

                let entryArtistKey = normalized(entry.artistName ?? "")
                if !requestedArtistKey.isEmpty {
                    if entryArtistKey == requestedArtistKey { score += 55 }
                    else if entryArtistKey.contains(requestedArtistKey) || requestedArtistKey.contains(entryArtistKey) { score += 30 }
                }

                if !coverKey.isEmpty && !entryArtistKey.isEmpty && coverKey.contains(entryArtistKey) {
                    score += 42
                }

                if best == nil || score > best!.score {
                    best = (score, synced)
                }
            }
        }

        guard let best, best.score >= 45 else { return [] }
        return parseLRC(best.lyrics)
    }

    private func cleanedTokens(from raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'&")).inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func cleanedTitle(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "_", with: " ")
        let patterns = [
            #"\s*[\(\[][^\)\]]*(extended|tour|intro|outro|edit|slowed|reverb|sped|speed|unreleased|remaster|instrumental|clean|explicit|official|lyrics?|visualizer|version|mix)[^\)\]]*[\)\]]"#,
            #"\s*(\||/|[-–—])\s*(extended\s+tour\s+intro|tour\s+intro|extended\s+intro|concert\s+intro|live\s+intro|intro\s+version|extended\s+version|tour\s+version|slowed(?:\s*&\s*reverb)?|sped\s+up|speed\s+up|edit|unreleased|official\s+audio|official\s+video|lyrics?|visualizer)\b.*$"#,
            #"\s+(extended\s+tour\s+intro|tour\s+intro|extended\s+intro|concert\s+intro|live\s+intro|intro\s+version|extended\s+version|tour\s+version|slowed(?:\s*&\s*reverb)?|sped\s+up|speed\s+up|unreleased|official\s+audio|official\s+video|lyrics?|visualizer|edit)\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        }

        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|/-–—")))
    }

    private func usefulArtist(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && !["unknown", "unknown artist", "various artists", "n/a", "na"].contains(value)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func overlapScore(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(words(lhs))
        let right = Set(words(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let common = left.intersection(right).count
        let total = left.union(right).count
        guard total > 0 else { return 0 }
        return Int((Double(common) / Double(total) * 65.0).rounded())
    }

    private func words(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func parseLRC(_ text: String) -> [LyricLine] {
        text.split(separator: "\n").compactMap { row in
            let string = String(row)
            guard let close = string.firstIndex(of: "]"), string.first == "[" else { return nil }
            let stamp = String(string[string.index(after: string.startIndex)..<close])
            let lyric = String(string[string.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let parts = stamp.split(separator: ":")
            guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return LyricLine(time: max(0, minutes * 60 + seconds), text: lyric)
        }
        .sorted { $0.time < $1.time }
    }
}
