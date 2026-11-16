import Foundation
import AVFoundation
import Accelerate

/// Serial, cancellable, bounded-memory analysis. The result is reused on the
/// next play; gain never changes part-way through the song being measured.
actor AudioLevelAnalyzer {
    static let shared = AudioLevelAnalyzer()
    private var cache: [String: Double] = {
        guard let data = UserDefaults.standard.data(forKey: "unsound.audioLevels.v1") else { return [:] }
        let decoded = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        return decoded.filter { $0.value.isFinite && (-18...0).contains($0.value) }
    }()

    private func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return url.lastPathComponent + "|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func cachedGain(for url: URL) -> Double? {
        cache[key(for: url)]
    }

    func analyze(_ url: URL) throws -> Double {
        let key = key(for: url)
        if let gain = cache[key] { return gain }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return 0 }
        var squareSum = 0.0
        var sampleCount = 0.0
        // Sample up to twelve 2-second windows distributed over the entire file.
        // This bounds work even for multi-hour imports and skips silent windows.
        let windowFrames = AVAudioFramePosition(file.processingFormat.sampleRate * 2)
        let windows = max(1, min(12, Int(file.length / max(1, windowFrames))))
        for index in 0..<windows {
            try Task.checkCancellation()
            file.framePosition = windows == 1 ? 0 : AVAudioFramePosition(Double(max(0, file.length - windowFrames)) * Double(index) / Double(windows - 1))
            var remaining = min(windowFrames, file.length - file.framePosition)
            while remaining > 0 {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                var windowSum = 0.0
                for channel in 0..<Int(buffer.format.channelCount) {
                    var sum: Float = 0
                    vDSP_svesq(channels[channel], 1, &sum, vDSP_Length(buffer.frameLength))
                    windowSum += Double(sum)
                }
                let count = Double(buffer.frameLength) * Double(buffer.format.channelCount)
                if windowSum / max(1, count) > 0.00000001 {
                    squareSum += windowSum
                    sampleCount += count
                }
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        }
        let gain = AudioLevelPolicy.matchingGainDB(rms: sqrt(squareSum / max(1, sampleCount)))
        // Cache is disposable and bounded independently of library size.
        if cache.count >= 1000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = gain
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: "unsound.audioLevels.v1")
        }
        return gain
    }
}
