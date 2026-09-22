import Foundation
import AVFoundation
import MediaPlayer
import Combine
import Accelerate
import UIKit

private struct SpectrumFrame {
    let bass: Double
    let mids: Double
    let highs: Double
    let dominantBassFrequency: Double
    let levels: [Double]
}

enum VisualPerformanceMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case smooth = "Smooth"
    case quality = "Quality"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .automatic: return "Reduces live visuals only when frame drops are detected"
        case .smooth: return "Prioritizes fast swiping and low UI load"
        case .quality: return "Keeps maximum waveform detail"
        }
    }
}

private struct AudioVisualState: Equatable {
    var bass = 0.0
    var mids = 0.0
    var highs = 0.0
    var dominantBassFrequency = 0.0
    var spectrum = Array(repeating: 0.0, count: 24)

    static let zero = AudioVisualState()
}

private final class SpectrumAnalyzerCore {
    private let fftSize = 2048
    private let visibleBandCount = 24
    private let queue = DispatchQueue(label: "com.unsound.spectrum", qos: .utility)
    private let stateLock = NSLock()
    private var setup: vDSP_DFT_Setup?
    private var window: [Float]
    private var minimumInterval: TimeInterval = 1.0 / 15.0
    private var lastAcceptedTime: TimeInterval = 0
    private var analysisEnabled = false

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    func configure(constrained: Bool, enabled: Bool) {
        stateLock.lock()
        minimumInterval = constrained ? (1.0 / 8.0) : (1.0 / 12.0)
        analysisEnabled = enabled
        if !enabled { lastAcceptedTime = 0 }
        stateLock.unlock()
    }

    private func shouldAnalyze() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        defer { stateLock.unlock() }

        guard analysisEnabled else { return false }
        guard lastAcceptedTime == 0 || now - lastAcceptedTime >= minimumInterval else { return false }
        lastAcceptedTime = now
        return true
    }

    func process(_ buffer: AVAudioPCMBuffer, completion: @escaping (SpectrumFrame) -> Void) {
        guard shouldAnalyze() else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = min(Int(buffer.frameLength), fftSize)
        guard count > 64 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        let sampleRate = buffer.format.sampleRate

        queue.async { [weak self] in
            guard let self, let setup = self.setup else { return }

            var inputReal = [Float](repeating: 0, count: self.fftSize)
            var inputImag = [Float](repeating: 0, count: self.fftSize)
            var outputReal = [Float](repeating: 0, count: self.fftSize)
            var outputImag = [Float](repeating: 0, count: self.fftSize)

            samples.withUnsafeBufferPointer { source in
                self.window.withUnsafeBufferPointer { win in
                    inputReal.withUnsafeMutableBufferPointer { target in
                        vDSP_vmul(
                            source.baseAddress!, 1,
                            win.baseAddress!, 1,
                            target.baseAddress!, 1,
                            vDSP_Length(count)
                        )
                    }
                }
            }

            vDSP_DFT_Execute(setup, inputReal, inputImag, &outputReal, &outputImag)

            let binHz = sampleRate / Double(self.fftSize)

            func peak(in range: ClosedRange<Double>) -> (level: Double, frequency: Double) {
                let lower = max(1, Int(range.lowerBound / binHz))
                let upper = min(self.fftSize / 2 - 1, Int(range.upperBound / binHz))
                guard lower <= upper else { return (0, 0) }

                var bestMagnitude: Float = 0
                var bestBin = lower

                for bin in lower...upper {
                    let magnitude = hypotf(outputReal[bin], outputImag[bin]) / Float(self.fftSize)
                    if magnitude > bestMagnitude {
                        bestMagnitude = magnitude
                        bestBin = bin
                    }
                }

                let db = 20.0 * log10(max(Double(bestMagnitude), 0.0000001))
                let normalized = min(1.0, max(0.0, (db + 68.0) / 54.0))
                return (normalized, Double(bestBin) * binHz)
            }

            let bassPeak = peak(in: 35...145)
            let midPeak = peak(in: 180...2500)
            let highPeak = peak(in: 2500...12000)

            let minimumHz = 35.0
            let maximumHz = min(12000.0, sampleRate * 0.48)
            let ratio = maximumHz / minimumHz
            var levels: [Double] = []
            levels.reserveCapacity(self.visibleBandCount)

            for index in 0..<self.visibleBandCount {
                let lowerFraction = Double(index) / Double(self.visibleBandCount)
                let upperFraction = Double(index + 1) / Double(self.visibleBandCount)
                let lowerHz = minimumHz * pow(ratio, lowerFraction)
                let upperHz = minimumHz * pow(ratio, upperFraction)
                levels.append(peak(in: lowerHz...upperHz).level)
            }

            completion(
                SpectrumFrame(
                    bass: bassPeak.level,
                    mids: midPeak.level,
                    highs: highPeak.level,
                    dominantBassFrequency: bassPeak.level > 0.04 ? bassPeak.frequency : 0,
                    levels: levels
                )
            )
        }
    }
}

@MainActor
final class AudioEngine: ObservableObject {
    enum RepeatMode: Int { case off = 0, playlist = 1, track = 2 }

    @Published var currentTrack: Track? = nil
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var bassDB: Double = 0 { didSet { applyBassProcessing() } }
    @Published var distortionAmount: Double = 0 { didSet { distortion.wetDryMix = Float(max(0, min(100, distortionAmount))) } }
    @Published var reverbAmount: Double = 0 { didSet { reverb.wetDryMix = Float(max(0, min(100, reverbAmount))) } }
    @Published var speed: Double = 1 { didSet { timePitch.rate = Float(max(0.5, min(2, speed))); updateNowPlaying() } }
    @Published var pitchSemitones: Double = 0 { didSet { timePitch.pitch = Float(pitchSemitones * 100) } }
    @Published var repeatMode: RepeatMode = .off
    @Published var outputMode: BassOutputMode {
        didSet {
            UserDefaults.standard.set(outputMode.rawValue, forKey: "bassOutputMode")
            applyBassProcessing()
        }
    }

    @Published private var visualState = AudioVisualState.zero
    @Published private(set) var performanceLimited = false
    @Published var visualPerformanceMode: VisualPerformanceMode {
        didSet {
            UserDefaults.standard.set(visualPerformanceMode.rawValue, forKey: "unsound.visualPerformanceMode")
            refreshPerformanceState()
        }
    }

    var visualBassEnergy: Double { visualState.bass }
    var visualMidEnergy: Double { visualState.mids }
    var visualHighEnergy: Double { visualState.highs }
    var dominantBassFrequency: Double { visualState.dominantBassFrequency }
    var visualSpectrum: [Double] { visualState.spectrum }
    var performanceStatusText: String {
        performanceLimited ? "Smooth visuals active" : "Full visual quality"
    }

    var onFinished: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onListenSample: ((Track, Double, Double) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    private let distortion = AVAudioUnitDistortion()
    private let reverb = AVAudioUnitReverb()
    private let timePitch = AVAudioUnitTimePitch()
    private let spectrumAnalyzer = SpectrumAnalyzerCore()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private var performanceProbeTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var scheduleID = UUID()
    private var unreportedListenSeconds: Double = 0
    private var timerTick = 0
    private var audioInterrupted = false
    private var appIsActive = true
    private var expectedPerformanceProbeTime: TimeInterval = 0
    private var adaptivePerformanceLimitedUntil: TimeInterval = 0

    init() {
        outputMode = BassOutputMode(rawValue: UserDefaults.standard.string(forKey: "bassOutputMode") ?? "") ?? .car
        visualPerformanceMode = VisualPerformanceMode(
            rawValue: UserDefaults.standard.string(forKey: "unsound.visualPerformanceMode") ?? ""
        ) ?? .automatic
        UIDevice.current.isBatteryMonitoringEnabled = true
        appIsActive = UIApplication.shared.applicationState == .active
        configureSession()
        configureGraph()
        configureRemoteCommands()
        configureNotifications()
        refreshPerformanceState()
        startTimer()
        startPerformanceProbe()
    }

    deinit {
        timer?.invalidate()
        performanceProbeTimer?.invalidate()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func load(track: Track, url: URL, autoplay: Bool = true) {
        do {
            reportListenIfNeeded(force: true)
            scheduleID = UUID()
            player.stop()
            file = try AVAudioFile(forReading: url)
            currentTrack = track
            duration = Double(file!.length) / file!.processingFormat.sampleRate
            currentTime = 0
            startFrame = 0
            unreportedListenSeconds = 0
            timerTick = 0
            visualState = .zero

            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info.removeValue(forKey: MPMediaItemPropertyArtwork)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }

            schedule(from: 0)
            if autoplay { play() } else { updateNowPlaying() }
        } catch {
            print("Audio load failed", error)
        }
    }

    func play() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying { player.play() }
            isPlaying = true
            refreshPerformanceState()
            updateNowPlaying()
        } catch {
            print("Audio engine start failed", error)
        }
    }

    func pause() {
        reportListenIfNeeded(force: true)
        player.pause()
        isPlaying = false
        refreshPerformanceState()
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: TimeInterval) {
        guard let f = file else { return }
        reportListenIfNeeded(force: true)
        let clamped = max(0, min(duration, seconds))
        let frame = AVAudioFramePosition(clamped * f.processingFormat.sampleRate)
        let resume = isPlaying
        scheduleID = UUID()
        player.stop()
        startFrame = frame
        currentTime = clamped
        schedule(from: frame)
        if resume { play() } else { updateNowPlaying() }
    }

    func apply(_ preset: AudioPreset) {
        // A track with no selected preset means the user is using device-level
        // manual tuning. Do not let the default NORMAL preset reset the knob
        // when auto-advancing to the next song.
        guard currentTrack?.selectedPresetID != nil else { return }
        bassDB = preset.bassDB
        distortionAmount = preset.distortion
        reverbAmount = preset.reverb
        speed = preset.speed
        pitchSemitones = preset.pitchSemitones
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("Audio session error", error)
        }
    }

    private func configureGraph() {
        let sub = eq.bands[0]
        sub.filterType = .lowShelf
        sub.frequency = 58
        sub.bandwidth = 1
        sub.gain = 0
        sub.bypass = false

        let slam = eq.bands[1]
        slam.filterType = .parametric
        slam.frequency = 78
        slam.bandwidth = 0.58
        slam.gain = 0
        slam.bypass = false

        let punch = eq.bands[2]
        punch.filterType = .parametric
        punch.frequency = 112
        punch.bandwidth = 0.82
        punch.gain = 0
        punch.bypass = false

        let mids = eq.bands[3]
        mids.filterType = .parametric
        mids.frequency = 880
        mids.bandwidth = 2.30
        mids.gain = 0
        mids.bypass = false

        let highs = eq.bands[4]
        highs.filterType = .highShelf
        highs.frequency = 3200
        highs.bandwidth = 1
        highs.gain = 0
        highs.bypass = false

        distortion.loadFactoryPreset(.multiBrokenSpeaker)
        distortion.wetDryMix = 0

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0

        engine.attach(player)
        engine.attach(eq)
        engine.attach(distortion)
        engine.attach(reverb)
        engine.attach(timePitch)
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: distortion, format: nil)
        engine.connect(distortion, to: reverb, format: nil)
        engine.connect(reverb, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        configureSpectrumTap()
        applyBassProcessing()
        engine.prepare()
    }

    private func configureSpectrumTap() {
        let analyzer = spectrumAnalyzer
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            analyzer.process(buffer) { frame in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    let attack: Double = self.performanceLimited ? 0.58 : 0.42
                    let release: Double = self.performanceLimited ? 0.30 : 0.17

                    func smooth(_ current: Double, _ target: Double) -> Double {
                        let amount = target > current ? attack : release
                        return current + (target - current) * amount
                    }

                    var next = self.visualState
                    next.bass = smooth(next.bass, frame.bass)
                    next.mids = smooth(next.mids, frame.mids)
                    next.highs = smooth(next.highs, frame.highs)

                    if next.spectrum.count != frame.levels.count {
                        next.spectrum = frame.levels
                    } else {
                        var nextSpectrum = next.spectrum
                        for index in frame.levels.indices {
                            nextSpectrum[index] = smooth(nextSpectrum[index], frame.levels[index])
                        }
                        next.spectrum = nextSpectrum
                    }

                    if frame.dominantBassFrequency > 0 {
                        if next.dominantBassFrequency <= 0 {
                            next.dominantBassFrequency = frame.dominantBassFrequency
                        } else {
                            next.dominantBassFrequency += (frame.dominantBassFrequency - next.dominantBassFrequency) * 0.32
                        }
                    } else {
                        next.dominantBassFrequency *= 0.84
                        if next.dominantBassFrequency < 8 { next.dominantBassFrequency = 0 }
                    }

                    // One published change per analyzer frame instead of five.
                    // This substantially reduces SwiftUI invalidations while swiping.
                    self.visualState = next
                }
            }
        }
    }

    private func applyBassProcessing() {
        let amount = max(0, min(30, bassDB))
        let x = amount / 30.0
        let shaped = pow(x, 1.10)

        let subGain: Double
        let slamGain: Double
        let punchGain: Double
        let midCut: Double
        let highCut: Double
        let headroom: Double
        let outputScale: Double

        switch outputMode {
        case .car:
            // Real subwoofers benefit from extension below 60 Hz, but the old
            // +19/+14.5 dB stack hit downstream limiters too early. Spread the
            // lift across sub/slam/punch and reserve more clean headroom.
            eq.bands[0].frequency = 48
            eq.bands[1].frequency = 66
            eq.bands[1].bandwidth = 0.60
            eq.bands[2].frequency = 103
            eq.bands[2].bandwidth = 0.92
            subGain = 12.5 * shaped
            slamGain = 9.5 * shaped
            punchGain = 5.5 * shaped
            midCut = -8.5 * pow(x, 1.12)
            highCut = -3.8 * pow(x, 1.08)
            headroom = -9.5 * shaped
            outputScale = 1.0 - (0.08 * x)

        case .crusherANC2:
            // Crusher already adds physical low-end via Sensory Bass. Boosting
            // the deepest bands too aggressively mainly drives its DSP limiter,
            // so emphasize 50–90 Hz and keep enough preamp headroom.
            eq.bands[0].frequency = 46
            eq.bands[1].frequency = 64
            eq.bands[1].bandwidth = 0.62
            eq.bands[2].frequency = 92
            eq.bands[2].bandwidth = 0.82
            subGain = 8.0 * shaped
            slamGain = 10.5 * shaped
            punchGain = 6.0 * shaped
            midCut = -6.5 * pow(x, 1.10)
            highCut = -2.8 * pow(x, 1.06)
            headroom = -10.0 * shaped
            outputScale = 1.0 - (0.06 * x)

        case .phone:
            // iPhone speakers cannot reproduce true 40–60 Hz sub-bass. Put the
            // energy where the speaker can actually create audible punch instead
            // of wasting headroom on inaudible lows.
            eq.bands[0].frequency = 118
            eq.bands[1].frequency = 155
            eq.bands[1].bandwidth = 0.80
            eq.bands[2].frequency = 210
            eq.bands[2].bandwidth = 1.05
            subGain = 1.0 * shaped
            slamGain = 4.5 * shaped
            punchGain = 4.0 * shaped
            midCut = -2.0 * pow(x, 1.04)
            highCut = -0.8 * pow(x, 1.02)
            headroom = -4.5 * shaped
            outputScale = 1.0 - (0.03 * x)
        }

        eq.bands[0].gain = Float(subGain)
        eq.bands[1].gain = Float(slamGain)
        eq.bands[2].gain = Float(punchGain)
        eq.bands[3].gain = Float(midCut)
        eq.bands[4].gain = Float(highCut)
        eq.globalGain = Float(headroom)
        engine.mainMixerNode.outputVolume = Float(max(0.78, outputScale))
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        let remaining = max(0, f.length - frame)
        guard remaining > 0 else { handleFinished(); return }
        let id = UUID()
        scheduleID = id
        player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.scheduleID == id else { return }
                self.handleFinished()
            }
        }
    }

    private func handleFinished() {
        reportListenIfNeeded(force: true)
        switch repeatMode {
        case .track:
            seek(to: 0)
            play()
        case .off, .playlist:
            isPlaying = false
            refreshPerformanceState()
            updateNowPlaying()
            onFinished?()
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let f = self.file, self.player.isPlaying else { return }

                self.timerTick &+= 1
                self.unreportedListenSeconds += 0.33
                self.reportListenIfNeeded()

                if self.performanceLimited && self.timerTick % 2 != 0 { return }

                guard let nodeTime = self.player.lastRenderTime,
                      let pTime = self.player.playerTime(forNodeTime: nodeTime) else { return }

                self.currentTime = min(
                    self.duration,
                    Double(self.startFrame + pTime.sampleTime) / f.processingFormat.sampleRate
                )

                // iOS extrapolates the Lock Screen position from elapsed time +
                // playback rate. Rewriting the complete Now Playing dictionary
                // every 330 ms only adds main-thread work while the user swipes.
            }
        }
        timer?.tolerance = 0.08
    }

    private func startPerformanceProbe() {
        let interval = 0.5
        expectedPerformanceProbeTime = ProcessInfo.processInfo.systemUptime + interval
        let probe = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measureMainThreadResponsiveness(interval: interval) }
        }
        probe.tolerance = 0.01
        RunLoop.main.add(probe, forMode: .common)
        performanceProbeTimer = probe
    }

    private func measureMainThreadResponsiveness(interval: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, now - expectedPerformanceProbeTime)
        expectedPerformanceProbeTime = now + interval

        if appIsActive, isPlaying, delay > 0.045 {
            adaptivePerformanceLimitedUntil = now + 8
            refreshPerformanceState()
        } else if adaptivePerformanceLimitedUntil > 0, now >= adaptivePerformanceLimitedUntil {
            adaptivePerformanceLimitedUntil = 0
            refreshPerformanceState()
        }
    }

    private func reportListenIfNeeded(force: Bool = false) {
        guard let track = currentTrack, unreportedListenSeconds > 0 else { return }
        guard force || unreportedListenSeconds >= 15 else { return }
        let seconds = unreportedListenSeconds
        unreportedListenSeconds = 0
        onListenSample?(track, seconds, bassDB)
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNext?() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func configureNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.configureSession()
                self?.refreshPerformanceState()
                if self?.isPlaying == true { self?.play() }
            }
        })

        let performanceNotifications: [Notification.Name] = [
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
            UIScreen.capturedDidChangeNotification,
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification
        ]

        for name in performanceNotifications {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPerformanceState() }
            })
        }

        notificationTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.appIsActive = true
                self?.refreshPerformanceState()
            }
        })

        notificationTokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.appIsActive = false
                self?.refreshPerformanceState()
            }
        })
    }

    private func refreshPerformanceState() {
        let process = ProcessInfo.processInfo
        let device = UIDevice.current

        let thermalLimited: Bool
        switch process.thermalState {
        case .serious, .critical:
            thermalLimited = true
        case .nominal, .fair:
            thermalLimited = false
        @unknown default:
            thermalLimited = false
        }

        let level = device.batteryLevel
        let lowBattery = level >= 0 && level <= 0.20 && device.batteryState != .charging && device.batteryState != .full
        let captured = UIScreen.main.isCaptured
        let systemConstrained = process.isLowPowerModeEnabled || lowBattery || thermalLimited || captured || audioInterrupted
        let now = process.systemUptime
        let adaptiveConstrained = visualPerformanceMode == .smooth ||
            (visualPerformanceMode == .automatic && now < adaptivePerformanceLimitedUntil)
        let constrained = systemConstrained || adaptiveConstrained

        if performanceLimited != constrained {
            performanceLimited = constrained
        }

        spectrumAnalyzer.configure(
            constrained: constrained,
            enabled: appIsActive && isPlaying && !audioInterrupted
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }

        switch type {
        case .began:
            reportListenIfNeeded(force: true)
            resumeAfterInterruption = isPlaying
            audioInterrupted = true
            isPlaying = false
            refreshPerformanceState()
            updateNowPlaying()

        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            audioInterrupted = false
            refreshPerformanceState()
            if resumeAfterInterruption && options.contains(.shouldResume) { play() }
            resumeAfterInterruption = false

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
        if reason == .oldDeviceUnavailable { pause() }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = track.id.uuidString
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func updateNowPlayingPosition() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
