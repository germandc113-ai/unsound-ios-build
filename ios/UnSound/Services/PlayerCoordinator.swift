import Foundation
import AVFoundation

@MainActor
final class PlayerCoordinator: ObservableObject {
    let audio: AudioEngine
    let library: LibraryStore
    @Published var queue: [UUID] = []
    @Published var lyrics: [LyricLine] = []
    @Published var showLyrics = false
    @Published var showFullPlayer = false
    @Published var previewingTrackID: UUID? = nil
    @Published var isLyricsSyncing = false
    @Published var lyricsSyncStatus: String? = nil

    private let lyricsService = LyricsService()
    private let lyricsAutoSyncService = LyricsAutoSyncService()
    private let artworkLyricsFallbackService = ArtworkLyricsFallbackService()
    private var baseLyrics: [LyricLine] = []
    private var baseLyricsTrackID: UUID? = nil
    private var artworkLyricHints: [UUID: [String]] = [:]
    private var previewPlayer: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?
    private var resumeMainAfterPreview = false
    private var randomAutoplayActive = false
    private let lyricsAutoSyncKeyPrefix = "unsound.lyricsAutoSynced."

    init(audio: AudioEngine, library: LibraryStore) {
        self.audio = audio
        self.library = library
        audio.onFinished = { [weak self] in self?.next() }
        audio.onNext = { [weak self] in self?.next() }
        audio.onPrevious = { [weak self] in self?.previous() }
        audio.onListenSample = { [weak self] track, seconds, bassDB in
            guard let self else { return }
            self.library.recordListen(track, seconds: seconds, bassDB: bassDB)
            ReplayHistory.recordListen(track: track, seconds: seconds, bassDB: bassDB)
        }
    }

    func play(_ track: Track, queue newQueue: [Track]? = nil) {
        stopPreview(resumeMain: false)
        guard let url = library.localURL(for: track) else { return }

        if let newQueue {
            randomAutoplayActive = shouldUseRandomAutoplay(for: newQueue)
            if randomAutoplayActive {
                queue = [track.id]
            } else {
                queue = newQueue.map(\.id)
            }
        } else if queue.isEmpty {
            queue = [track.id]
        }

        audio.load(track: track, url: url)
        audio.updateSystemArtwork(for: track)
        library.recordPlay(track)
        ReplayHistory.recordPlay(track: track)
        if let p = selectedPreset(for: track) { audio.apply(p) }
        Task { await loadLyrics(track) }
    }

    func preview(_ track: Track, seconds: Double = 12) {
        guard let url = library.localURL(for: track) else { return }

        if previewingTrackID == track.id {
            stopPreview()
            return
        }

        let shouldResume = previewingTrackID == nil ? audio.isPlaying : resumeMainAfterPreview
        stopPreview(resumeMain: false)
        resumeMainAfterPreview = shouldResume

        if audio.isPlaying { audio.pause() }

        do {
            let candidate = try AVAudioPlayer(contentsOf: url)
            candidate.prepareToPlay()
            candidate.currentTime = 0
            candidate.play()
            previewPlayer = candidate
            previewingTrackID = track.id

            let previewLength = max(3, min(seconds, candidate.duration > 0 ? candidate.duration : seconds))
            previewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(previewLength * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stopPreview()
            }
        } catch {
            previewPlayer = nil
            previewingTrackID = nil
            if shouldResume { audio.play() }
        }
    }

    func stopPreview(resumeMain: Bool = true) {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewingTrackID = nil

        let shouldResume = resumeMainAfterPreview
        resumeMainAfterPreview = false
        if resumeMain && shouldResume { audio.play() }
    }

    func next() {
        guard let current = audio.currentTrack else { return }

        if randomAutoplayActive {
            if let idx = queue.firstIndex(of: current.id), idx + 1 < queue.count,
               let forward = library.track(queue[idx + 1]) {
                play(forward)
                return
            }

            let recentIDs = Set(queue.suffix(6))
            let playable = library.tracks.filter {
                $0.id != current.id &&
                library.localURL(for: $0) != nil &&
                !library.isSuggestionHidden($0.id)
            }
            let fresh = playable.filter { !recentIDs.contains($0.id) }
            let candidates = fresh.isEmpty ? playable : fresh

            guard let randomTrack = candidates.randomElement() else {
                audio.pause()
                return
            }

            queue.append(randomTrack.id)
            if queue.count > 40 {
                queue.removeFirst(queue.count - 40)
            }
            play(randomTrack)
            return
        }

        guard let idx = queue.firstIndex(of: current.id), !queue.isEmpty else { return }
        let nextIdx = (idx + 1) % queue.count
        if audio.repeatMode == .off && nextIdx == 0 {
            audio.pause()
            return
        }
        if let t = library.track(queue[nextIdx]) { play(t) }
    }

    func previous() {
        guard let current = audio.currentTrack else { return }
        if audio.currentTime > 4 { audio.seek(to: 0); return }

        if randomAutoplayActive {
            guard let idx = queue.firstIndex(of: current.id), idx > 0,
                  let previousTrack = library.track(queue[idx - 1]) else {
                audio.seek(to: 0)
                return
            }
            play(previousTrack)
            return
        }

        guard let idx = queue.firstIndex(of: current.id), !queue.isEmpty else { return }
        let previousIndex = idx == 0 ? queue.count - 1 : idx - 1
        if let t = library.track(queue[previousIndex]) { play(t) }
    }

    func cycleRepeatMode() {
        switch audio.repeatMode {
        case .off: audio.repeatMode = .playlist
        case .playlist: audio.repeatMode = .track
        case .track: audio.repeatMode = .off
        }
    }

    func choosePreset(_ preset: AudioPreset) {
        guard var t = audio.currentTrack, let i = library.tracks.firstIndex(where: { $0.id == t.id }) else { return }
        library.tracks[i].selectedPresetID = preset.id
        library.save()
        t.selectedPresetID = preset.id
        audio.currentTrack = t
        audio.apply(preset)
    }

    func setBassDB(_ value: Double) {
        audio.bassDB = min(30, max(0, value))
        markManualTuning()
    }

    func setDistortion(_ value: Double) {
        audio.distortionAmount = min(100, max(0, value))
        markManualTuning()
    }

    func setReverb(_ value: Double) {
        audio.reverbAmount = min(100, max(0, value))
        markManualTuning()
    }

    func setSpeed(_ value: Double) {
        audio.speed = min(2, max(0.5, value))
        markManualTuning()
    }

    func saveCurrentAsPreset(name: String) {
        guard var t = audio.currentTrack, let i = library.tracks.firstIndex(where: { $0.id == t.id }) else { return }
        let p = AudioPreset(name: name, bassDB: audio.bassDB, distortion: audio.distortionAmount, reverb: audio.reverbAmount, speed: audio.speed, pitchSemitones: audio.pitchSemitones)
        t.presets.append(p)
        t.selectedPresetID = p.id
        library.tracks[i] = t
        library.save()
        audio.currentTrack = t
    }

    private func markManualTuning() {
        guard var current = audio.currentTrack,
              current.selectedPresetID != nil,
              let index = library.tracks.firstIndex(where: { $0.id == current.id }) else { return }

        current.selectedPresetID = nil
        audio.currentTrack = current
        library.tracks[index].selectedPresetID = nil
        library.save()
    }

    private func selectedPreset(for track: Track) -> AudioPreset? {
        if let id = track.selectedPresetID { return track.presets.first { $0.id == id } }
        return track.presets.first
    }

    private func shouldUseRandomAutoplay(for tracks: [Track]) -> Bool {
        let ids = tracks.map(\.id)
        guard !ids.isEmpty else { return false }

        if ids == library.likedTracks.map(\.id) {
            return false
        }

        if library.playlists.contains(where: { $0.trackIDs == ids }) {
            return false
        }

        return true
    }

    func loadLyrics(_ track: Track) async {
        lyricsSyncStatus = nil
        do {
            let base = try await lookupBaseLyrics(for: track)
            guard audio.currentTrack?.id == track.id else { return }

            baseLyrics = base
            baseLyricsTrackID = track.id
            let current = library.track(track.id) ?? track
            lyrics = lyricsService.shifted(base, byMilliseconds: current.introOffsetMs)

            guard !base.isEmpty else {
                let cleaned = lyricsService.cleanedLookupTitle(track.title)
                lyricsSyncStatus = cleaned.isEmpty
                    ? "No synced lyrics found."
                    : "No synced lyrics found for \(cleaned)."
                return
            }

            let key = lyricsAutoSyncKeyPrefix + track.id.uuidString
            if !UserDefaults.standard.bool(forKey: key), library.localURL(for: current) != nil {
                await autoSyncLyrics(force: false)
            }
        } catch {
            guard audio.currentTrack?.id == track.id else { return }
            baseLyrics = []
            baseLyricsTrackID = track.id
            lyrics = []
            lyricsSyncStatus = "Lyrics lookup failed. Tap FIND LYRICS to retry."
        }
    }

    func retryLyricsLookup() async {
        guard !isLyricsSyncing, let current = audio.currentTrack else { return }

        isLyricsSyncing = true
        lyricsSyncStatus = "Searching title, artist and artwork…"

        do {
            artworkLyricHints.removeValue(forKey: current.id)
            let base = try await lookupBaseLyrics(for: current)
            guard audio.currentTrack?.id == current.id else {
                isLyricsSyncing = false
                return
            }

            baseLyrics = base
            baseLyricsTrackID = current.id
            let stored = library.track(current.id) ?? current
            lyrics = lyricsService.shifted(base, byMilliseconds: stored.introOffsetMs)

            guard !base.isEmpty else {
                let cleaned = lyricsService.cleanedLookupTitle(current.title)
                lyricsSyncStatus = cleaned.isEmpty
                    ? "No synced lyrics found."
                    : "Still no synced lyrics for \(cleaned)."
                isLyricsSyncing = false
                return
            }

            lyricsSyncStatus = "Lyrics found. Aligning…"
            UserDefaults.standard.removeObject(forKey: lyricsAutoSyncKeyPrefix + current.id.uuidString)
            isLyricsSyncing = false
            await autoSyncLyrics(force: true)
        } catch {
            guard audio.currentTrack?.id == current.id else {
                isLyricsSyncing = false
                return
            }
            lyricsSyncStatus = "Lyrics lookup failed. Check connection and retry."
            isLyricsSyncing = false
        }
    }

    func autoSyncLyrics(force: Bool = true) async {
        guard !isLyricsSyncing,
              let current = audio.currentTrack,
              let localURL = library.localURL(for: current) else { return }

        let key = lyricsAutoSyncKeyPrefix + current.id.uuidString
        if !force && UserDefaults.standard.bool(forKey: key) { return }

        isLyricsSyncing = true
        lyricsSyncStatus = "Analyzing vocal start…"
        defer { isLyricsSyncing = false }

        do {
            let base: [LyricLine]
            if baseLyricsTrackID == current.id && !baseLyrics.isEmpty {
                base = baseLyrics
            } else {
                base = try await lookupBaseLyrics(for: current)
                guard audio.currentTrack?.id == current.id else { return }
                baseLyrics = base
                baseLyricsTrackID = current.id
            }

            guard let firstLyric = base.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                lyricsSyncStatus = "No synced lyric timing found."
                return
            }

            guard let vocalStart = await lyricsAutoSyncService.estimateVocalStart(url: localURL) else {
                guard audio.currentTrack?.id == current.id else { return }
                lyricsSyncStatus = "AUTO SYNC could not find a clear vocal start."
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            guard audio.currentTrack?.id == current.id else { return }

            let rawOffset = vocalStart - firstLyric.time
            let clamped = min(90.0, max(-15.0, rawOffset))
            let offsetMs = abs(clamped) < 0.30 ? 0 : Int((clamped * 1000).rounded())

            library.updateIntroOffset(current.id, milliseconds: offsetMs)
            if let refreshed = library.track(current.id) {
                audio.currentTrack = refreshed
            }
            lyrics = lyricsService.shifted(base, byMilliseconds: offsetMs)
            UserDefaults.standard.set(true, forKey: key)

            let sign = offsetMs >= 0 ? "+" : ""
            lyricsSyncStatus = "AUTO SYNC \(sign)\(String(format: "%.1f", Double(offsetMs) / 1000.0)) s"
        } catch {
            lyricsSyncStatus = "AUTO SYNC failed."
        }
    }

    func adjustLyricsOffset(byMilliseconds delta: Int) {
        guard let current = audio.currentTrack else { return }
        let stored = library.track(current.id) ?? current
        let next = min(90_000, max(-15_000, stored.introOffsetMs + delta))
        library.updateIntroOffset(current.id, milliseconds: next)
        if let refreshed = library.track(current.id) {
            audio.currentTrack = refreshed
        }
        if baseLyricsTrackID == current.id {
            lyrics = lyricsService.shifted(baseLyrics, byMilliseconds: next)
        }
        let sign = next >= 0 ? "+" : ""
        lyricsSyncStatus = "Manual offset \(sign)\(String(format: "%.1f", Double(next) / 1000.0)) s"
    }

    func resetLyricsOffset() {
        guard let current = audio.currentTrack else { return }
        library.updateIntroOffset(current.id, milliseconds: 0)
        if let refreshed = library.track(current.id) {
            audio.currentTrack = refreshed
        }
        if baseLyricsTrackID == current.id {
            lyrics = baseLyrics
        }
        UserDefaults.standard.removeObject(forKey: lyricsAutoSyncKeyPrefix + current.id.uuidString)
        lyricsSyncStatus = "Original lyric timing"
    }

    var currentLyricsOffsetMs: Int {
        guard let current = audio.currentTrack else { return 0 }
        return library.track(current.id)?.introOffsetMs ?? current.introOffsetMs
    }

    /// Normal metadata lookup first. If that returns nothing, OCR is run on
    /// the current cover and recognized rapper/title words are used as a
    /// conservative LRCLIB fallback. Title similarity still has to match, so
    /// random cover text cannot silently attach unrelated lyrics.
    private func lookupBaseLyrics(for track: Track) async throws -> [LyricLine] {
        let normal = try await lyricsService.fetchBaseLyrics(title: track.title, artist: track.artist)
        if !normal.isEmpty { return normal }

        let words: [String]
        if let cached = artworkLyricHints[track.id] {
            words = cached
        } else if let data = await artworkData(for: track) {
            lyricsSyncStatus = "Reading artist/title from artwork…"
            let recognized = await artworkLyricsFallbackService.recognizeText(in: data)
            artworkLyricHints[track.id] = recognized
            words = recognized
        } else {
            words = []
        }

        guard !words.isEmpty else { return [] }
        lyricsSyncStatus = "Trying artwork text with LRCLIB…"
        return try await artworkLyricsFallbackService.fetchSyncedLyrics(
            title: lyricsService.cleanedLookupTitle(track.title),
            artist: track.artist,
            artworkWords: words
        )
    }

    private func artworkData(for track: Track) async -> Data? {
        if let localURL = library.customArtworkURL(for: track),
           let data = try? Data(contentsOf: localURL) {
            return data
        }

        guard let raw = track.artworkURL, let url = URL(string: raw) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
