import Foundation
import SoundAnalysis
import CoreMedia

/// One-shot, on-device helper for aligning synced lyrics to local intro/edit files.
/// It uses Apple's built-in sound classifier to find the first likely vocal,
/// speech or rap section. Analysis runs only when AUTO SYNC is requested (or
/// once for a track that has never been synced), not continuously during play.
final class LyricsAutoSyncService {
    func estimateVocalStart(url: URL) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let observer = VocalObserver()
                    let analyzer = try SNAudioFileAnalyzer(url: url)
                    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                    request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
                    request.overlapFactor = 0.55
                    try analyzer.add(request, withObserver: observer)
                    analyzer.analyze()
                    continuation.resume(returning: observer.earliestVocalStart)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private final class VocalObserver: NSObject, SNResultsObserving {
    private(set) var earliestVocalStart: TimeInterval?

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        guard earliestVocalStart == nil else { return }

        let vocalHints = ["sing", "speech", "voice", "vocal", "rap", "chant", "spoken"]
        let match = classification.classifications.first { item in
            guard item.confidence >= 0.18 else { return false }
            let id = item.identifier.lowercased()
            return vocalHints.contains(where: { id.contains($0) })
        }

        guard match != nil else { return }
        earliestVocalStart = max(0, classification.timeRange.start.seconds)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { }
    func requestDidComplete(_ request: SNRequest) { }
}
