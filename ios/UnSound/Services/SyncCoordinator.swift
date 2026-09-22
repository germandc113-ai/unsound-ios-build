import Foundation
import Network
import UIKit
import Combine

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var isPaired = false
    @Published private(set) var connectedDeviceCount = 1
    @Published private(set) var serverName = "Windows companion"
    @Published var status = "Local only"
    @Published private(set) var lastHost: String
    @Published var deviceName: String

    var endpoint: URL? = nil
    var ownerToken: String

    private let port = NWEndpoint.Port(rawValue: 51_337)!
    private let networkQueue = DispatchQueue(label: "com.unsound.windows-link", qos: .userInitiated)
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pendingPairingCode = ""
    private var sessionToken: String?
    private var playbackTimer: Timer?
    private var syncPlaybackTask: Task<Void, Never>?
    private var audioCancellables = Set<AnyCancellable>()
    private var restoringDeviceAudioSettings = false
    private var tickCounter = 0
    private var lastLibrarySignature = ""

    private weak var audio: AudioEngine?
    private weak var library: LibraryStore?
    private weak var player: PlayerCoordinator?

    private enum AudioSettingKey {
        static let bass = "unsound.deviceAudio.bassDB"
        static let distortion = "unsound.deviceAudio.distortion"
        static let reverb = "unsound.deviceAudio.reverb"
        static let speed = "unsound.deviceAudio.speed"
        static let pitch = "unsound.deviceAudio.pitch"
        static let repeatMode = "unsound.deviceAudio.repeatMode"
        static let outputMode = "unsound.deviceAudio.outputMode"
    }

    private struct WireMessage: Codable {
        var type: String
        var code: String? = nil
        var ownerToken: String? = nil
        var deviceID: String? = nil
        var deviceName: String? = nil
        var sessionToken: String? = nil
        var serverName: String? = nil
        var connectedDeviceCount: Int? = nil
        var library: DesktopLibrary? = nil
        var playback: DesktopPlayback? = nil
        var command: DesktopCommand? = nil
        var message: String? = nil
    }

    private struct DesktopLibrary: Codable {
        var tracks: [DesktopTrack]
        var playlists: [DesktopPlaylist]
    }

    private struct DesktopTrack: Codable {
        var id: String
        var title: String
        var artist: String
        var isLiked: Bool
        var source: String
        var sourceID: String?
        var artworkURL: String?
    }

    private struct DesktopPlaylist: Codable {
        var id: String
        var title: String
        var trackIDs: [String]
        var isPinned: Bool
    }

    private struct DesktopPlayback: Codable {
        var trackID: String?
        var title: String?
        var artist: String?
        var source: String?
        var sourceID: String?
        var position: Double
        var duration: Double
        var isPlaying: Bool
        var bassDB: Double
        var distortion: Double
        var reverb: Double
        var speed: Double
        var pitchSemitones: Double
        var repeatMode: Int
        var outputMode: String
    }

    private struct DesktopCommand: Codable {
        var name: String
        var value: Double?
        var stringValue: String?
        var playback: DesktopPlayback?
        var executeAtUnixMs: Int64?
    }

    init() {
        let defaults = UserDefaults.standard
        let storedToken = defaults.string(forKey: "ownerToken") ?? UUID().uuidString
        ownerToken = storedToken
        lastHost = defaults.string(forKey: "unsound.windowsLink.lastHost") ?? ""
        deviceName = defaults.string(forKey: "unsound.windowsLink.deviceName") ?? UIDevice.current.name
        defaults.set(storedToken, forKey: "ownerToken")
        if defaults.string(forKey: "unsound.windowsLink.deviceID") == nil {
            defaults.set(UUID().uuidString, forKey: "unsound.windowsLink.deviceID")
        }
    }

    deinit {
        playbackTimer?.invalidate()
        syncPlaybackTask?.cancel()
        audioCancellables.removeAll()
        connection?.cancel()
    }

    private var deviceID: String {
        UserDefaults.standard.string(forKey: "unsound.windowsLink.deviceID") ?? UUID().uuidString
    }

    func attach(audio: AudioEngine, library: LibraryStore, player: PlayerCoordinator) {
        self.audio = audio
        self.library = library
        self.player = player
        configureDeviceAudioPersistence(audio)

        guard playbackTimer == nil else { return }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncTick() }
        }
    }

    func saveDeviceName(_ rawName: String) {
        let clean = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else {
            status = "Enter a device name"
            return
        }
        deviceName = clean
        UserDefaults.standard.set(clean, forKey: "unsound.windowsLink.deviceName")
        status = isPaired ? "Name saved • reconnect to update Windows" : "Device name saved"
    }

    func connect(host: String, pairingCode: String) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanHost.isEmpty else {
            status = "Enter the Windows IP address"
            return
        }
        guard cleanCode.count == 6, cleanCode.allSatisfy(\.isNumber) else {
            status = "Enter the 6 digit pairing code"
            return
        }

        disconnect(silent: true)
        lastHost = cleanHost
        pendingPairingCode = cleanCode
        UserDefaults.standard.set(cleanHost, forKey: "unsound.windowsLink.lastHost")
        status = "Connecting to \(cleanHost)…"

        let newConnection = NWConnection(host: NWEndpoint.Host(cleanHost), port: port, using: .tcp)
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = "Pairing…"
                    self.beginReceive()
                    self.sendPairRequest()
                case .waiting(let error):
                    self.status = "Waiting: \(error.localizedDescription)"
                case .failed(let error):
                    self.status = "Connection failed: \(error.localizedDescription)"
                    self.isPaired = false
                    self.connectedDeviceCount = 1
                case .cancelled:
                    self.isPaired = false
                    self.connectedDeviceCount = 1
                default:
                    break
                }
            }
        }
        newConnection.start(queue: networkQueue)
    }

    func disconnect() { disconnect(silent: false) }

    func syncLibraryNow() {
        guard isPaired, let library else {
            if !isPaired { status = "Pair with Windows first" }
            return
        }

        let payload = DesktopLibrary(
            tracks: library.tracks.map {
                DesktopTrack(
                    id: $0.id.uuidString,
                    title: $0.title,
                    artist: $0.artist,
                    isLiked: $0.isLiked,
                    source: $0.source,
                    sourceID: $0.sourceID,
                    artworkURL: $0.artworkURL
                )
            },
            playlists: library.playlists.map {
                DesktopPlaylist(id: $0.id.uuidString, title: $0.title, trackIDs: $0.trackIDs.map(\.uuidString), isPinned: $0.isPinned)
            }
        )
        send(WireMessage(type: "library", library: payload))
        lastLibrarySignature = librarySignature()
        status = "Connected • library synced"
    }

    func syncNow(snapshot: PlaybackSnapshot) async {
        guard isPaired else {
            status = "Windows companion not connected"
            return
        }
        sendPlaybackNow()
    }

    private func configureDeviceAudioPersistence(_ audio: AudioEngine) {
        audioCancellables.removeAll()
        let defaults = UserDefaults.standard

        if defaults.object(forKey: AudioSettingKey.bass) == nil { defaults.set(audio.bassDB, forKey: AudioSettingKey.bass) }
        if defaults.object(forKey: AudioSettingKey.distortion) == nil { defaults.set(audio.distortionAmount, forKey: AudioSettingKey.distortion) }
        if defaults.object(forKey: AudioSettingKey.reverb) == nil { defaults.set(audio.reverbAmount, forKey: AudioSettingKey.reverb) }
        if defaults.object(forKey: AudioSettingKey.speed) == nil { defaults.set(audio.speed, forKey: AudioSettingKey.speed) }
        if defaults.object(forKey: AudioSettingKey.pitch) == nil { defaults.set(audio.pitchSemitones, forKey: AudioSettingKey.pitch) }
        if defaults.object(forKey: AudioSettingKey.repeatMode) == nil { defaults.set(audio.repeatMode.rawValue, forKey: AudioSettingKey.repeatMode) }
        if defaults.string(forKey: AudioSettingKey.outputMode) == nil { defaults.set(audio.outputMode.rawValue, forKey: AudioSettingKey.outputMode) }

        applyStoredDeviceAudioSettings()

        audio.$currentTrack
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.restoringDeviceAudioSettings = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyStoredDeviceAudioSettings()
                    self.restoringDeviceAudioSettings = false
                }
            }
            .store(in: &audioCancellables)

        audio.$bassDB.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value, forKey: AudioSettingKey.bass)
        }.store(in: &audioCancellables)

        audio.$distortionAmount.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value, forKey: AudioSettingKey.distortion)
        }.store(in: &audioCancellables)

        audio.$reverbAmount.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value, forKey: AudioSettingKey.reverb)
        }.store(in: &audioCancellables)

        audio.$speed.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value, forKey: AudioSettingKey.speed)
        }.store(in: &audioCancellables)

        audio.$pitchSemitones.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value, forKey: AudioSettingKey.pitch)
        }.store(in: &audioCancellables)

        audio.$repeatMode.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value.rawValue, forKey: AudioSettingKey.repeatMode)
        }.store(in: &audioCancellables)

        audio.$outputMode.dropFirst().sink { [weak self] value in
            guard let self, !self.restoringDeviceAudioSettings else { return }
            UserDefaults.standard.set(value.rawValue, forKey: AudioSettingKey.outputMode)
        }.store(in: &audioCancellables)
    }

    private func applyStoredDeviceAudioSettings() {
        guard let audio else { return }
        let defaults = UserDefaults.standard
        let wasRestoring = restoringDeviceAudioSettings
        restoringDeviceAudioSettings = true

        audio.bassDB = min(30, max(0, defaults.double(forKey: AudioSettingKey.bass)))
        audio.distortionAmount = min(100, max(0, defaults.double(forKey: AudioSettingKey.distortion)))
        audio.reverbAmount = min(100, max(0, defaults.double(forKey: AudioSettingKey.reverb)))

        let storedSpeed = defaults.double(forKey: AudioSettingKey.speed)
        audio.speed = min(2, max(0.5, storedSpeed > 0 ? storedSpeed : 1))
        audio.pitchSemitones = min(24, max(-24, defaults.double(forKey: AudioSettingKey.pitch)))
        audio.repeatMode = AudioEngine.RepeatMode(rawValue: defaults.integer(forKey: AudioSettingKey.repeatMode)) ?? .off

        if let raw = defaults.string(forKey: AudioSettingKey.outputMode), let mode = BassOutputMode(rawValue: raw) {
            audio.outputMode = mode
        }

        restoringDeviceAudioSettings = wasRestoring
    }

    private func syncTick() {
        guard isPaired else { return }
        sendPlaybackNow()
        tickCounter += 1
        guard tickCounter % 4 == 0 else { return }
        let signature = librarySignature()
        if signature != lastLibrarySignature { syncLibraryNow() }
    }

    private func sendPairRequest() {
        send(
            WireMessage(
                type: "pair",
                code: pendingPairingCode,
                ownerToken: ownerToken,
                deviceID: deviceID,
                deviceName: deviceName
            ),
            includeSession: false
        )
    }

    private func sendPlaybackNow() {
        guard isPaired, let audio else { return }
        let payload = DesktopPlayback(
            trackID: audio.currentTrack?.id.uuidString,
            title: audio.currentTrack?.title,
            artist: audio.currentTrack?.artist,
            source: audio.currentTrack?.source,
            sourceID: audio.currentTrack?.sourceID,
            position: max(0, audio.currentTime),
            duration: max(0, audio.duration),
            isPlaying: audio.isPlaying,
            bassDB: audio.bassDB,
            distortion: audio.distortionAmount,
            reverb: audio.reverbAmount,
            speed: audio.speed,
            pitchSemitones: audio.pitchSemitones,
            repeatMode: audio.repeatMode.rawValue,
            outputMode: audio.outputMode.rawValue
        )
        send(WireMessage(type: "playback", playback: payload))
    }

    private func beginReceive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.consumeIncomingLines()
                }
                if let error {
                    self.status = "Windows link lost: \(error.localizedDescription)"
                    self.isPaired = false
                    self.connectedDeviceCount = 1
                    return
                }
                if isComplete {
                    self.status = "Windows companion disconnected"
                    self.isPaired = false
                    self.connectedDeviceCount = 1
                    return
                }
                self.beginReceive()
            }
        }
    }

    private func consumeIncomingLines() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = Data(receiveBuffer[..<newline])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(WireMessage.self, from: line)
                handle(message)
            } catch {
                status = "Windows sent an unreadable message"
            }
        }
    }

    private func handle(_ message: WireMessage) {
        switch message.type {
        case "paired":
            guard let token = message.sessionToken, !token.isEmpty else {
                status = "Windows did not return a secure session"
                disconnect(silent: true)
                return
            }
            sessionToken = token
            serverName = message.serverName ?? "UnSound Windows"
            isPaired = true
            connectedDeviceCount = max(2, message.connectedDeviceCount ?? 2)
            status = "Connected to \(serverName)"
            lastLibrarySignature = ""
            syncLibraryNow()
            sendPlaybackNow()

        case "deviceCount":
            guard isPaired,
                  let expected = sessionToken,
                  message.sessionToken == expected else { return }
            connectedDeviceCount = max(2, message.connectedDeviceCount ?? connectedDeviceCount)

        case "error":
            status = message.message ?? "Pairing failed"
            if !isPaired {
                sessionToken = nil
                connectedDeviceCount = 1
            }

        case "command":
            guard isPaired,
                  let expected = sessionToken,
                  message.sessionToken == expected,
                  let command = message.command else {
                status = "Rejected unauthenticated Windows command"
                return
            }
            execute(command)

        default:
            break
        }
    }

    private func execute(_ command: DesktopCommand) {
        switch command.name {
        case "toggle": audio?.toggle()
        case "play": audio?.play()
        case "pause": audio?.pause()
        case "next": player?.next()
        case "previous": player?.previous()
        case "seek": if let value = command.value { audio?.seek(to: value) }
        case "setBass": if let value = command.value { player?.setBassDB(value) }
        case "setDistortion": if let value = command.value { player?.setDistortion(value) }
        case "setReverb": if let value = command.value { player?.setReverb(value) }
        case "setSpeed": if let value = command.value { player?.setSpeed(value) }
        case "setPitch": if let value = command.value { audio?.pitchSemitones = min(24, max(-24, value)) }
        case "setOutputMode":
            if let raw = command.stringValue, let mode = BassOutputMode(rawValue: raw) { audio?.outputMode = mode }
        case "cycleRepeat": player?.cycleRepeatMode()
        case "syncLibrary": syncLibraryNow()
        case "syncPlayback":
            guard let target = command.playback else { return }
            applySynchronizedPlayback(target, executeAtUnixMs: command.executeAtUnixMs)
            return
        default: return
        }
        sendPlaybackNow()
    }

    private func applySynchronizedPlayback(_ target: DesktopPlayback, executeAtUnixMs: Int64?) {
        guard let audio, let library else { return }
        guard let track = findSyncedTrack(target, in: library), let url = library.localURL(for: track) else {
            status = "SYNC ALL: song is not downloaded on this iPhone"
            return
        }

        syncPlaybackTask?.cancel()
        audio.pause()

        if audio.currentTrack?.id != track.id {
            audio.load(track: track, url: url, autoplay: false)
            Task { [weak self] in await self?.player?.loadLyrics(track) }
        }

        audio.seek(to: max(0, min(target.position, audio.duration)))

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delayMs = max(0, (executeAtUnixMs ?? nowMs) - nowMs)
        status = "SYNC ALL • \(track.title)"

        syncPlaybackTask = Task { @MainActor [weak self] in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            if target.isPlaying { self.audio?.play() } else { self.audio?.pause() }
            self.sendPlaybackNow()
        }
    }

    private func findSyncedTrack(_ target: DesktopPlayback, in library: LibraryStore) -> Track? {
        if let source = target.source,
           let sourceID = target.sourceID,
           !sourceID.isEmpty,
           let exact = library.track(source: source, sourceID: sourceID),
           library.localURL(for: exact) != nil {
            return exact
        }

        if let id = target.trackID,
           let uuid = UUID(uuidString: id),
           let exactID = library.track(uuid),
           library.localURL(for: exactID) != nil {
            return exactID
        }

        let wantedTitle = normalize(target.title ?? "")
        let wantedArtist = normalize(target.artist ?? "")
        guard !wantedTitle.isEmpty else { return nil }
        return library.tracks.first {
            library.localURL(for: $0) != nil &&
            normalize($0.title) == wantedTitle &&
            (wantedArtist.isEmpty || normalize($0.artist) == wantedArtist)
        }
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func send(_ message: WireMessage, includeSession: Bool = true) {
        guard let connection else { return }
        do {
            var secured = message
            if includeSession, secured.type != "pair" {
                guard let sessionToken, !sessionToken.isEmpty else {
                    status = "Secure Windows session missing"
                    return
                }
                secured.sessionToken = sessionToken
            }
            var data = try JSONEncoder().encode(secured)
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.status = "Send failed: \(error.localizedDescription)" }
            })
        } catch {
            status = "Could not encode sync data"
        }
    }

    private func librarySignature() -> String {
        guard let library else { return "" }
        let tracks = library.tracks.map {
            "\($0.id.uuidString)|\($0.title)|\($0.artist)|\($0.isLiked)|\($0.source)|\($0.sourceID ?? "")"
        }.joined(separator: ";")
        let playlists = library.playlists.map {
            "\($0.id.uuidString)|\($0.title)|\($0.isPinned)|\($0.trackIDs.map(\.uuidString).joined(separator: ","))"
        }.joined(separator: ";")
        return tracks + "#" + playlists
    }

    private func disconnect(silent: Bool) {
        syncPlaybackTask?.cancel()
        syncPlaybackTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        pendingPairingCode = ""
        sessionToken = nil
        isPaired = false
        connectedDeviceCount = 1
        if !silent { status = "Local only" }
    }
}
