import Foundation
import AVFoundation

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let first = scratch.appendingPathComponent("first.mp3")
let renamed = scratch.appendingPathComponent("renamed.mp3")
let different = scratch.appendingPathComponent("different.mp3")
try Data("same audio bytes".utf8).write(to: first)
try FileManager.default.copyItem(at: first, to: renamed)
try Data("diff audio bytes".utf8).write(to: different)
let firstHash = try FileFingerprint.sha256(of: first)
let renamedHash = try FileFingerprint.sha256(of: renamed)
let differentHash = try FileFingerprint.sha256(of: different)
assert(firstHash == renamedHash)
assert(firstHash != differentHash)
print("Content fingerprints: renamed duplicates detected; same-size different files preserved")

let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
source.frameLength = 44100
for i in 0..<44100 {
    source.floatChannelData![0][i] = Float(1.8 * sin(2 * Double.pi * 100 * Double(i) / 44100))
}
func renderPeak(limited: Bool) throws -> Float {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let limiter = AudioOutputProtection.makeLimiter()
    limiter.bypass = !limited
    engine.attach(player)
    engine.attach(limiter)
    engine.connect(player, to: limiter, format: format)
    engine.connect(limiter, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0.89
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    player.scheduleBuffer(source)
    try engine.start()
    player.play()
    defer { engine.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var peak: Float = 0
    for _ in 0..<50 {
        let status = try engine.renderOffline(1024, to: output)
        assert(status == .success)
        for index in 0..<Int(output.frameLength) {
            peak = max(peak, abs(output.floatChannelData![0][index]))
        }
    }
    return peak
}
let unprotectedPeak = try renderPeak(limited: false)
let protectedPeak = try renderPeak(limited: true)
assert(unprotectedPeak > 1.4)
assert(protectedPeak > 0.1 && protectedPeak <= 1.01, "Peak limiter exceeded full scale: \(protectedPeak)")
print("Offline audio rendering: peak \(unprotectedPeak) without limiter, \(protectedPeak) with limiter")

let testFile = scratch.appendingPathComponent("level.caf")
try autoreleasepool {
    let file = try AVAudioFile(forWriting: testFile, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
    buffer.frameLength = 44100
    for i in 0..<44100 { buffer.floatChannelData![0][i] = 0.5 }
    try file.write(from: buffer)
}
// Run actor work without blocking the cooperative executor used by top-level code.
let finished = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let measured = try await AudioLevelAnalyzer.shared.analyze(testFile)
        assert(abs(measured - AudioLevelPolicy.matchingGainDB(rms: 0.5)) < 0.1)
        let cached = await AudioLevelAnalyzer.shared.cachedGain(for: testFile)
        assert(cached == measured)
        print("Background audio level measurement and cache passed")
    } catch {
        fatalError("Audio level test failed: \(error)")
    }
    finished.signal()
}
assert(finished.wait(timeout: .now() + 20) == .success)
