import Foundation

extension LyricsService {
    private var cloudManualOverridesKey: String { "unsound.manualLyricsOverrides.v1" }

    func exportManualLyrics() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cloudManualOverridesKey) as? [String: String] ?? [:]
    }

    func importManualLyrics(_ incoming: [String: String]) {
        guard !incoming.isEmpty else { return }
        var merged = exportManualLyrics()
        for (key, value) in incoming where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if merged[key] == nil {
                merged[key] = value
            }
        }
        UserDefaults.standard.set(merged, forKey: cloudManualOverridesKey)
    }
}
