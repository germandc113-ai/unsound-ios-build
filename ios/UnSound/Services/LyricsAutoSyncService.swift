import Foundation
import SoundAnalysis
import CoreMedia

/// Stop at the first detected vocal or after the opening 90 seconds. Skipping
/// cancels the classifier instead of leaving an entire song analyzing behind it.
final class LyricsAutoSyncService {
    func estimateVocalStart(url: URL) async -> TimeInterval? {
        let cancellation = VocalAnalysisCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let analyzer = try SNAudioFileAnalyzer(url: url)
                        guard cancellation.install(analyzer) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let observer = VocalObserver(analyzer: analyzer)
                        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
                        request.overlapFactor = 0.55
                        try analyzer.add(request, withObserver: observer)
                        analyzer.analyze()
                        continuation.resume(returning: cancellation.isCancelled ? nil : observer.earliestVocalStart)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class VocalAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SNAudioFileAnalyzer?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ analyzer: SNAudioFileAnalyzer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.analyzer = analyzer
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = analyzer
        lock.unlock()
        current?.cancelAnalysis()
    }
}

private final class VocalObserver: NSObject, SNResultsObserving {
    private(set) var earliestVocalStart: TimeInterval?
    private weak var analyzer: SNAudioFileAnalyzer?

    init(analyzer: SNAudioFileAnalyzer) { self.analyzer = analyzer }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult,
              earliestVocalStart == nil else { return }
        if classification.timeRange.start.seconds >= 90 {
            analyzer?.cancelAnalysis()
            return
        }
        let vocalHints = ["sing", "speech", "voice", "vocal", "rap", "chant", "spoken"]
        let match = classification.classifications.first { item in
            item.confidence >= 0.18 && vocalHints.contains { item.identifier.lowercased().contains($0) }
        }
        guard match != nil else { return }
        earliestVocalStart = max(0, classification.timeRange.start.seconds)
        analyzer?.cancelAnalysis()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { }
    func requestDidComplete(_ request: SNRequest) { }
}
