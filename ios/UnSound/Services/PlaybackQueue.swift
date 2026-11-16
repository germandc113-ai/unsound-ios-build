import Foundation

/// Queue operations do not change library or playlist ordering.
enum PlaybackQueue {
    static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func libraryOrder(existing: [UUID], playable: [UUID], current: UUID) -> [UUID] {
        let available = Set(playable)
        var seen = Set<UUID>()
        let ordered = (existing + playable).filter { available.contains($0) && seen.insert($0).inserted }
        guard let index = ordered.firstIndex(of: current) else { return ordered }
        return Array(ordered[index...]) + Array(ordered[..<index])
    }

    static func advancing(_ queue: [UUID], past current: UUID) -> [UUID] {
        guard queue.first == current else { return queue }
        return Array(queue.dropFirst()) + [current]
    }
}
