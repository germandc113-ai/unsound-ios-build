import Foundation

extension LibraryStore {
    /// Attaches a downloaded shared-audio object to an existing cloud/reference
    /// track without creating a second Track record. If the track already has a
    /// live local file, the existing file wins and the download is ignored.
    @discardableResult
    func attachSharedAudio(
        to trackID: UUID,
        from sourceURL: URL,
        preferredExtension: String
    ) throws -> Track {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw NSError(
                domain: "UnSound.SharedAudio",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Shared track no longer exists in the library."]
            )
        }

        if localURL(for: tracks[index]) != nil {
            return tracks[index]
        }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDirectory = documents.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        let fallbackExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawExtension = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeExtension = sanitizedAudioExtension(!rawExtension.isEmpty ? rawExtension : fallbackExtension)
        let storedName = "\(UUID().uuidString).\(safeExtension)"
        let destination = mediaDirectory.appendingPathComponent(storedName)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        tracks[index].localFilename = storedName
        let updated = tracks[index]
        save()
        return updated
    }

    /// Clears every currently queued duplicate-review item in one action. This
    /// is intentionally equivalent to pressing DENY on each item and never
    /// deletes any already-imported track.
    @discardableResult
    func skipAllDuplicateImports() -> Int {
        let count = duplicateImportQueue.count
        while currentDuplicateImport != nil {
            denyCurrentDuplicate()
        }
        return count
    }

    private func sanitizedAudioExtension(_ raw: String) -> String {
        let supported = Set(["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"])
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return supported.contains(cleaned) ? cleaned : "m4a"
    }
}
