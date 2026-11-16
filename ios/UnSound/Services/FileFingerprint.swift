import Foundation
import CryptoKit
import AVFoundation

enum FileFingerprint {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Serial hashing avoids a burst of concurrent disk reads during bulk import.
actor ImportFingerprintCache {
    static let shared = ImportFingerprintCache()
    private var cache: [String: String] = [:]

    func validateAudio(_ url: URL) throws {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw NSError(domain: "UnSound.Import", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "Empty or unreadable audio file"])
        }
    }

    func copy(from source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func audioFiles(in root: URL, extensions: Set<String>) -> [URL] {
        let manager = FileManager.default
        if (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return extensions.contains(root.pathExtension.lowercased()) ? [root] : []
        }
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return iterator.compactMap { $0 as? URL }.filter {
            extensions.contains($0.pathExtension.lowercased()) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func fingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = url.path + "|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let saved = cache[key] { return saved }
        let hash = try FileFingerprint.sha256(of: url)
        if cache.count >= 2000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = hash
        return hash
    }
}
