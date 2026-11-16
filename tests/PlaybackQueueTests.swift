import Foundation

let songs = (0..<150).map { _ in UUID() }
var queue = PlaybackQueue.libraryOrder(existing: Array(songs.prefix(5)), playable: songs, current: songs[2])
assert(queue.count == 150 && Set(queue).count == 150)
assert(queue.first == songs[2])
let original = queue
var visited = Set<UUID>()
for _ in songs.indices {
    let current = queue[0]
    assert(visited.insert(current).inserted, "Repeated before visiting the entire library")
    queue = PlaybackQueue.advancing(queue, past: current)
    assert(queue.last == current, "Skipped song must move to the bottom")
}
assert(queue == original && visited == Set(songs))
let removed = songs[12]
let added = UUID()
let playable = songs.filter { $0 != removed } + [added]
queue = PlaybackQueue.libraryOrder(existing: queue + [queue[0]], playable: playable, current: songs[3])
assert(queue.count == 150 && Set(queue) == Set(playable))
assert(queue.first == songs[3] && !queue.contains(removed))
assert(PlaybackQueue.libraryOrder(existing: songs, playable: [], current: songs[0]).isEmpty)
assert(PlaybackQueue.advancing([], past: songs[0]).isEmpty)
assert(PlaybackQueue.advancing([songs[0]], past: songs[0]) == [songs[0]])
assert(PlaybackQueue.advancing([songs[1]], past: songs[0]) == [songs[1]])
print("Playback queue: 150-song rotation, full coverage, additions, deletions, duplicates, empty and single-song queues passed")
