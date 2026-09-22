import Foundation

struct AudioPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bassDB: Double
    var distortion: Double
    var reverb: Double
    var speed: Double
    var pitchSemitones: Double

    static let normal = AudioPreset(name: "NORMAL", bassDB: 0, distortion: 0, reverb: 0, speed: 1, pitchSemitones: 0)
    static let car = AudioPreset(name: "CAR", bassDB: 10, distortion: 0, reverb: 0, speed: 1, pitchSemitones: 0)
    static let max808 = AudioPreset(name: "808 MAX", bassDB: 24, distortion: 0, reverb: 0, speed: 1, pitchSemitones: 0)
    static let destroyed = AudioPreset(name: "DESTROYED", bassDB: 30, distortion: 55, reverb: 8, speed: 0.96, pitchSemitones: -1)
}

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var artist: String
    var source: String = "local"
    var sourceID: String? = nil
    var localFilename: String? = nil
    var artworkURL: String? = nil
    var customArtworkFilename: String? = nil
    var providerURL: String? = nil
    var introOffsetMs: Int = 0
    var presets: [AudioPreset] = [.normal, .car, .max808, .destroyed]
    var selectedPresetID: UUID? = nil
    var isLiked: Bool = false
    var dateAdded = Date()
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var trackIDs: [UUID] = []
    var isPinned = false
    var coverPath: String? = nil
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

struct PlaybackSnapshot: Codable {
    var trackID: UUID
    var position: Double
    var repeatMode: Int
    var presetID: UUID?
    var speed: Double
    var pitchSemitones: Double
    var sentAt: Date = Date()
}

struct ListeningStats: Codable {
    var secondsByTrack: [String: Double] = [:]
    var playsByTrack: [String: Int] = [:]
    var repeats: Int = 0
    var bassSamples: [Double] = []
    var presetUses: [String: Int] = [:]
}

enum SearchSource: String, CaseIterable, Identifiable {
    case audius = "Audius"
    case youtube = "YouTube"
    case soundcloud = "SoundCloud"
    var id: String { rawValue }
}

enum SearchCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case artists = "Artists"
    case playlists = "Playlists"
    var id: String { rawValue }
}

struct ProviderSearchResult: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var artworkURL: String?
    var durationText: String?
    var kind: SearchCategory
    var source: SearchSource
    var isDownloadable: Bool = false
    var isPreviewable: Bool = false
    var providerURL: String? = nil
}
