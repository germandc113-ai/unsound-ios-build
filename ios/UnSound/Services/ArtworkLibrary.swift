import Foundation
import MediaPlayer
import UIKit

private let nowPlayingArtworkCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 24
    return cache
}()

private let customArtworkImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 24
    return cache
}()

@MainActor
extension LibraryStore {
    func customArtworkURL(for track: Track) -> URL? {
        guard let filename = track.customArtworkFilename ?? self.track(track.id)?.customArtworkFilename else { return nil }
        let url = artworkDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func customArtworkImage(for track: Track) -> UIImage? {
        guard let filename = track.customArtworkFilename ?? self.track(track.id)?.customArtworkFilename else { return nil }
        let key = filename as NSString

        if let cached = customArtworkImageCache.object(forKey: key) {
            return cached
        }

        let url = artworkDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = UIImage(contentsOfFile: url.path) else { return nil }

        customArtworkImageCache.setObject(image, forKey: key)
        return image
    }

    @discardableResult
    func applyCustomArtwork(_ data: Data, to trackIDs: Set<UUID>) throws -> [Track] {
        guard !trackIDs.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)

        let filename = "\(UUID().uuidString).jpg"
        let destination = artworkDirectory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)

        if let image = UIImage(data: data) {
            customArtworkImageCache.setObject(image, forKey: filename as NSString)
        }

        var changed: [Track] = []
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].customArtworkFilename = filename
            changed.append(tracks[index])
        }
        save()
        cleanupUnusedArtwork()
        return changed
    }

    @discardableResult
    func removeCustomArtwork(from trackIDs: Set<UUID>) -> [Track] {
        guard !trackIDs.isEmpty else { return [] }
        var changed: [Track] = []
        var removedFilenames = Set<String>()

        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            if let filename = tracks[index].customArtworkFilename {
                removedFilenames.insert(filename)
            }
            tracks[index].customArtworkFilename = nil
            changed.append(tracks[index])
        }

        for filename in removedFilenames {
            customArtworkImageCache.removeObject(forKey: filename as NSString)
        }

        save()
        cleanupUnusedArtwork()
        return changed
    }

    private var artworkDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    private func cleanupUnusedArtwork() {
        let used = Set(tracks.compactMap(\.customArtworkFilename))
        guard let files = try? FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !used.contains(file.lastPathComponent) {
            customArtworkImageCache.removeObject(forKey: file.lastPathComponent as NSString)
            try? FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor
extension AudioEngine {
    /// Keeps the selected cover in the system Now Playing dictionary. iOS then
    /// decides the exact Lock Screen and Dynamic Island presentation.
    func updateSystemArtwork(for track: Track) {
        guard currentTrack?.id == track.id else { return }
        currentTrack = track

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist

        if let filename = track.customArtworkFilename {
            let key = filename as NSString
            if let cached = customArtworkImageCache.object(forKey: key) {
                setSystemArtwork(cached, in: &info)
            } else {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Artwork", isDirectory: true)
                    .appendingPathComponent(filename)
                info.removeValue(forKey: MPMediaItemPropertyArtwork)
                Task { [weak self] in
                    guard let self else { return }
                    let image = await Task.detached(priority: .utility) {
                        UIImage(contentsOfFile: url.path)
                    }.value
                    guard let image, self.currentTrack?.id == track.id else { return }
                    customArtworkImageCache.setObject(image, forKey: key)
                    var refreshed = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    self.setSystemArtwork(image, in: &refreshed)
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = refreshed
                }
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        guard let rawURL = track.artworkURL, let url = URL(string: rawURL) else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        if let cached = nowPlayingArtworkCache.object(forKey: rawURL as NSString) {
            setSystemArtwork(cached, in: &info)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        info.removeValue(forKey: MPMediaItemPropertyArtwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data), self.currentTrack?.id == track.id else { return }
                nowPlayingArtworkCache.setObject(image, forKey: rawURL as NSString)
                var refreshed = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                self.setSystemArtwork(image, in: &refreshed)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = refreshed
            } catch {
                // Artwork failure must never interrupt audio playback.
            }
        }
    }

    private func setSystemArtwork(_ image: UIImage, in info: inout [String: Any]) {
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            let scale = min(
                requestedSize.width / max(1, image.size.width),
                requestedSize.height / max(1, image.size.height)
            )
            guard scale < 1 else { return image }
            let target = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            return UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        }
    }
}
