import Foundation

struct PlaybackSession: Codable {
    var queue: [UUID]
    var repeatQueue: [UUID]
    var history: [UUID]
    var currentID: UUID
    var position: Double
    var repeatMode: Int

    func reconciled(playable: [UUID]) -> PlaybackSession? {
        let available = Set(playable)
        guard !available.isEmpty else { return nil }
        let current = available.contains(currentID) ? currentID : (queue.first { available.contains($0) } ?? playable[0])
        let mode = (0...2).contains(repeatMode) ? repeatMode : 0
        let scope = repeatQueue.filter { available.contains($0) }
        let restored = mode == 0
            ? PlaybackQueue.libraryOrder(existing: queue, playable: playable, current: current)
            : PlaybackQueue.unique(scope.isEmpty ? [current] : scope)
        return PlaybackSession(queue: restored, repeatQueue: scope.isEmpty ? [current] : scope,
                               history: history.filter { available.contains($0) }, currentID: current,
                               position: current == currentID && position.isFinite ? max(0, position) : 0,
                               repeatMode: mode)
    }
}

/// A separate small snapshot keeps queue checkpoints out of library/stat writes.
enum PlaybackSessionStore {
    private static let key = "unsound.playbackSession.v1"

    static func load() -> PlaybackSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlaybackSession.self, from: data)
    }

    static func save(_ session: PlaybackSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
