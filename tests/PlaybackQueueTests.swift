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

// The test size is deliberately above both 150 and typical page limits.
let largeLibrary = (0..<4096).map { _ in UUID() }
let old = PlaybackSession(queue: Array(largeLibrary.prefix(150)), repeatQueue: Array(largeLibrary.prefix(5)),
                          history: [largeLibrary[0]], currentID: largeLibrary[2], position: 37.5, repeatMode: 0)
let roundTrip = try JSONDecoder().decode(PlaybackSession.self, from: JSONEncoder().encode(old))
let restored = roundTrip.reconciled(playable: largeLibrary)!
assert(restored.queue.count == 4096 && restored.queue.first == largeLibrary[2])
assert(restored.position == 37.5 && restored.repeatQueue.count == 5)
var playlistSession = old
playlistSession.repeatMode = 1
assert(playlistSession.reconciled(playable: largeLibrary)!.queue == Array(largeLibrary.prefix(5)))
playlistSession.repeatMode = 2
assert(playlistSession.reconciled(playable: largeLibrary)!.currentID == largeLibrary[2])
let missing = old.reconciled(playable: [largeLibrary[7]])!
assert(missing.currentID == largeLibrary[7] && missing.position == 0)
assert(old.reconciled(playable: []) == nil)
var invalid = old
invalid.position = .infinity
invalid.repeatMode = 99
assert(invalid.reconciled(playable: largeLibrary)!.position == 0)
assert(invalid.reconciled(playable: largeLibrary)!.repeatMode == 0)
assert(AudioLevelPolicy.matchingGainDB(rms: 0) == 0)
assert(AudioLevelPolicy.matchingGainDB(rms: .nan) == 0)
assert(AudioLevelPolicy.matchingGainDB(rms: 0.001) == 0)
assert(AudioLevelPolicy.matchingGainDB(rms: 0.5) < -11)
assert(AudioLevelPolicy.matchingGainDB(rms: 1) == -18)
assert(AudioLevelPolicy.clampedTrim(100) == 6 && AudioLevelPolicy.clampedTrim(-100) == -6)
print("Session round trip, 4096-song growth, repeat scopes, deleted songs and gain bounds passed")

// Existing library files predate contentFingerprint; they must still decode.
let legacyTrack = Track(title: "Existing song", artist: "Artist")
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyTrack)) as! [String: Any]
legacyJSON.removeValue(forKey: "contentFingerprint")
let decodedLegacy = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
assert(decodedLegacy.id == legacyTrack.id && decodedLegacy.contentFingerprint == nil)
PlaybackSessionStore.save(old)
assert(PlaybackSessionStore.load()?.position == 37.5)
print("Old library compatibility and saved playback checkpoint passed")

assert(AudioLevelPolicy.scaledTrim(6, bassDB: 0) == 0)
assert(AudioLevelPolicy.scaledTrim(-6, bassDB: 0) == 0)
assert(AudioLevelPolicy.scaledTrim(6, bassDB: 15) == 3)
assert(AudioLevelPolicy.scaledTrim(6, bassDB: 30) == 6)
print("Master bass control scales all detail boosts and switches them off at zero")
