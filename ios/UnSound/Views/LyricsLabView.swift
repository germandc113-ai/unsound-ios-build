import SwiftUI
import AVFoundation

private enum LyricsOffsetUnit: String, CaseIterable, Identifiable {
    case seconds = "SEC"
    case milliseconds = "MS"
    var id: String { rawValue }
}

struct LyricsLabView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var peaks: [CGFloat] = []
    @State private var isLoadingWaveform = true
    @State private var zoom = 2.4
    @State private var offsetUnit: LyricsOffsetUnit = .seconds
    @State private var offsetText = "0.000"
    @State private var labSpeed = 1.0
    @State private var originalSpeed: Double?
    @State private var status: String?

    @State private var searchQuery = ""
    @State private var searchResults: [LyricsService.ManualSearchResult] = []
    @State private var isSearching = false
    @State private var searchStatus: String?
    @State private var showPasteLRC = false
    @State private var pastedLRC = ""

    private let lyricsService = LyricsService()

    private var currentOffsetMs: Int { player.currentLyricsOffsetMs }

    private var enteredOffsetMs: Int? {
        let raw = offsetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value.isFinite else { return nil }
        switch offsetUnit {
        case .seconds: return Int((value * 1000).rounded())
        case .milliseconds: return Int(value.rounded())
        }
    }

    private var previewDelta: TimeInterval {
        Double((enteredOffsetMs ?? currentOffsetMs) - currentOffsetMs) / 1000
    }

    private var previewActiveLine: LyricLine? {
        player.lyrics.last { $0.time + previewDelta <= audio.currentTime }
    }

    private var firstBaseLyricTime: TimeInterval? {
        guard let first = player.lyrics.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return first.time - Double(currentOffsetMs) / 1000
    }

    private var proposedMarkerTime: TimeInterval? {
        guard let base = firstBaseLyricTime, let targetOffset = enteredOffsetMs else { return nil }
        return max(0, base + Double(targetOffset) / 1000)
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    lyricsSearchSection
                    waveformSection
                    speedSection
                    offsetSection
                    lyricPreview
                    applySection
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            originalSpeed = audio.speed
            labSpeed = min(1, max(0.5, audio.speed))
            audio.speed = labSpeed
            loadOffsetText(from: currentOffsetMs)
            prefillSearch()
            loadWaveform()
        }
        .onDisappear {
            if let originalSpeed { audio.speed = originalSpeed }
        }
        .onChange(of: offsetUnit) { _, _ in
            loadOffsetText(from: enteredOffsetMs ?? currentOffsetMs)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .black))
                    .frame(width: 42, height: 42)
                    .usGlass(Circle(), interactive: true)
            }
            .buttonStyle(USPressStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text("LYRICS LAB")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                Text("Find the right lyrics, then line them up exactly.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
            }
            Spacer()
        }
    }

    private var lyricsSearchSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MANUAL LYRICS SEARCH")
                        .font(.caption.bold())
                        .tracking(1.4)
                        .foregroundStyle(USTheme.tertiary)
                    Text("FIND LYRICS outside the Lab stays automatic. This search is fully manual.")
                        .font(.caption2)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(USTheme.secondary)
                TextField("Artist + song title", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await searchLyrics() }
                    }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                        searchStatus = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(USTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 48)
            .usGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)

            HStack(spacing: 9) {
                Button {
                    Task { await searchLyrics() }
                } label: {
                    HStack(spacing: 7) {
                        if isSearching {
                            ProgressView().tint(.white).scaleEffect(0.82)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(AppLocalization.text(isSearching ? "SEARCHING" : "SEARCH"))
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(USPressStyle())
                .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    withAnimation(.snappy(duration: 0.18)) { showPasteLRC.toggle() }
                } label: {
                    Label("PASTE LRC", systemImage: "doc.on.clipboard")
                        .font(.caption.bold())
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
                }
                .buttonStyle(USPressStyle())
            }

            if let searchStatus {
                Text(AppLocalization.text(searchStatus))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(USTheme.secondary)
            }

            if showPasteLRC {
                VStack(spacing: 9) {
                    TextEditor(text: $pastedLRC)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 150)
                        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))

                    Button {
                        Task { await usePastedLRC() }
                    } label: {
                        Text("USE PASTED LRC")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .usGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true, tint: USTheme.accent.opacity(0.12))
                    }
                    .buttonStyle(USPressStyle())
                    .disabled(pastedLRC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !searchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(searchResults.prefix(8)) { result in
                        HStack(spacing: 11) {
                            Image(systemName: result.hasSyncedLyrics ? "quote.bubble.fill" : "text.alignleft")
                                .foregroundStyle(result.hasSyncedLyrics ? USTheme.accent : USTheme.secondary)
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(result.artist)
                                    .font(.caption)
                                    .foregroundStyle(USTheme.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if result.hasSyncedLyrics {
                                Button("USE") {
                                    Task { await useSearchResult(result) }
                                }
                                .font(.caption2.bold())
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .usGlass(Capsule(), interactive: true, tint: USTheme.accent.opacity(0.14))
                                .buttonStyle(USPressStyle())
                            } else {
                                Text("NO SYNC")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .foregroundStyle(USTheme.tertiary)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 25, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WAVEFORM TIMELINE")
                        .font(.caption.bold())
                        .tracking(1.5)
                        .foregroundStyle(USTheme.tertiary)
                    Text("Tap to seek • zoom • use the bookmark at the exact first lyric")
                        .font(.caption2)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
                Text(String(format: "×%.1f", zoom))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(USTheme.accent)
            }

            GeometryReader { outer in
                Group {
                    if isLoadingWaveform {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Building waveform…")
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if peaks.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "waveform.slash")
                                .font(.title2)
                                .foregroundStyle(USTheme.secondary)
                            Text("Waveform unavailable for this file.")
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal) {
                            LabWaveform(
                                peaks: peaks,
                                duration: audio.duration,
                                currentTime: audio.currentTime,
                                markerTime: proposedMarkerTime,
                                onSeek: { audio.seek(to: $0) }
                            )
                            .frame(
                                width: max(outer.size.width, outer.size.width * CGFloat(zoom)),
                                height: 184
                            )
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .frame(height: 184)
            .padding(10)
            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.07)))

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(USTheme.secondary)
                Slider(value: $zoom, in: 1...8)
                    .tint(USTheme.accent)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(USTheme.secondary)
            }

            HStack(spacing: 10) {
                Text(time(audio.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(USTheme.secondary)

                Spacer()

                Button {
                    markCurrentPositionAsFirstLyric()
                } label: {
                    Label("MARK FIRST LYRIC HERE", systemImage: "bookmark.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .usGlass(Capsule(), interactive: true, tint: USTheme.accent.opacity(0.12))
                }
                .buttonStyle(USPressStyle())
                .disabled(firstBaseLyricTime == nil)

                Spacer()

                Text(time(audio.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(USTheme.secondary)
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRECISION PLAYBACK")
                        .font(.caption.bold())
                        .tracking(1.4)
                        .foregroundStyle(USTheme.tertiary)
                    Text("Slow the song down temporarily to hit the exact millisecond.")
                        .font(.caption2)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
                Text(String(format: "%.2fx", labSpeed))
                    .font(.caption.monospacedDigit().bold())
            }

            Slider(value: $labSpeed, in: 0.5...1.0, step: 0.05)
                .tint(USTheme.accent)
                .onChange(of: labSpeed) { _, newValue in audio.speed = newValue }

            HStack(spacing: 8) {
                speedButton(0.50)
                speedButton(0.75)
                speedButton(1.00)
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(USPressStyle())

                Button { audio.toggle() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 42, height: 42)
                        .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.12))
                }
                .buttonStyle(USPressStyle())

                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var offsetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LYRICS OFFSET")
                .font(.caption.bold())
                .tracking(1.4)
                .foregroundStyle(USTheme.tertiary)

            HStack(spacing: 10) {
                TextField(offsetUnit == .seconds ? "0.000" : "0", text: $offsetText)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 14)
                    .frame(height: 54)
                    .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)

                Picker("Offset unit", selection: $offsetUnit) {
                    ForEach(LyricsOffsetUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
            }

            HStack {
                Text("Type it directly, e.g. 18.237 sec or 18237 ms")
                    .font(.caption2)
                    .foregroundStyle(USTheme.secondary)
                Spacer()
                Button("CURRENT") { loadOffsetText(from: currentOffsetMs) }
                    .font(.caption2.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(USTheme.accent)
            }

            if enteredOffsetMs == nil {
                Text("Enter a valid number.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(USTheme.accent)
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var lyricPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LIVE LYRIC PREVIEW")
                .font(.caption.bold())
                .tracking(1.4)
                .foregroundStyle(USTheme.tertiary)

            Text(previewActiveLine?.text.isEmpty == false ? previewActiveLine!.text : "♪")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.75)

            if let offset = enteredOffsetMs {
                Text("Preview offset: \(signedOffset(offset))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(USTheme.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private var applySection: some View {
        VStack(spacing: 10) {
            Button { applyLyricsOffset() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.waveform")
                    Text("APPLY LYRICS SYNC")
                }
                .font(.headline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .buttonStyle(USPressStyle())
            .disabled(enteredOffsetMs == nil || player.lyrics.isEmpty)
            .opacity(enteredOffsetMs == nil || player.lyrics.isEmpty ? 0.38 : 1)

            Text("APPLY only saves the lyrics timing. Search, waveform zoom and slow playback do not change your bass or normal song settings.")
                .font(.caption2)
                .foregroundStyle(USTheme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let status {
                Text(AppLocalization.text(status))
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func speedButton(_ value: Double) -> some View {
        Button {
            labSpeed = value
            audio.speed = value
        } label: {
            Text(String(format: "%.2fx", value))
                .font(.caption2.bold().monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(labSpeed == value ? Color.white.opacity(0.09) : Color.clear, in: Capsule())
                .usGlass(Capsule(), interactive: true)
        }
        .buttonStyle(USPressStyle())
    }

    private func prefillSearch() {
        guard let track = audio.currentTrack else { return }
        let title = lyricsService.cleanedLookupTitle(track.title)
        searchQuery = [track.artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown" && $0.lowercased() != "unknown artist" }
            .joined(separator: " ")
    }

    private func searchLyrics() async {
        guard !isSearching else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        searchStatus = nil
        do {
            searchResults = try await lyricsService.manualSearch(title: "", artist: "", freeQuery: query)
            searchStatus = searchResults.isEmpty
                ? "No matching LRCLIB results. Try artist + exact song title or paste an LRC."
                : "\(searchResults.count) result\(searchResults.count == 1 ? "" : "s") found."
        } catch {
            searchResults = []
            searchStatus = "Search failed. Check the connection and try again."
        }
        isSearching = false
    }

    private func useSearchResult(_ result: LyricsService.ManualSearchResult) async {
        guard let track = audio.currentTrack else { return }
        guard lyricsService.saveManualResult(result, forTitle: track.title, artist: track.artist) else {
            searchStatus = "That result has no synced timestamps."
            return
        }

        searchStatus = "Loading selected lyrics…"
        await player.retryLyricsLookup()
        loadOffsetText(from: player.currentLyricsOffsetMs)
        searchStatus = player.lyrics.isEmpty ? "Could not load that result." : "Lyrics loaded. Use the waveform below to line them up."
    }

    private func usePastedLRC() async {
        guard let track = audio.currentTrack else { return }
        guard lyricsService.saveManualLRC(pastedLRC, title: track.title, artist: track.artist) else {
            searchStatus = "No valid [mm:ss.xxx] timestamps found in that text."
            return
        }

        searchStatus = "Loading pasted lyrics…"
        await player.retryLyricsLookup()
        loadOffsetText(from: player.currentLyricsOffsetMs)
        searchStatus = player.lyrics.isEmpty ? "Could not load that LRC." : "LRC loaded. Now align it on the waveform."
    }

    private func markCurrentPositionAsFirstLyric() {
        guard let base = firstBaseLyricTime else {
            status = "Load synced lyrics first."
            return
        }

        let seconds = min(90.0, max(-15.0, audio.currentTime - base))
        let milliseconds = Int((seconds * 1000).rounded())
        loadOffsetText(from: milliseconds)
        status = "Bookmark set at \(time(audio.currentTime)). Press APPLY when it lines up."
    }

    private func applyLyricsOffset() {
        guard let target = enteredOffsetMs else { return }
        let clamped = min(90_000, max(-15_000, target))
        let delta = clamped - player.currentLyricsOffsetMs
        player.adjustLyricsOffset(byMilliseconds: delta)
        loadOffsetText(from: player.currentLyricsOffsetMs)
        status = "Applied \(signedOffset(player.currentLyricsOffsetMs))"
    }

    private func loadOffsetText(from milliseconds: Int) {
        switch offsetUnit {
        case .seconds: offsetText = String(format: "%.3f", Double(milliseconds) / 1000)
        case .milliseconds: offsetText = String(milliseconds)
        }
    }

    private func loadWaveform() {
        guard let track = audio.currentTrack,
              let url = player.library.localURL(for: track) else {
            isLoadingWaveform = false
            peaks = []
            return
        }

        isLoadingWaveform = true
        Task {
            let result = await LyricsWaveformAnalyzer.peaks(for: url, targetCount: 1600)
            guard audio.currentTrack?.id == track.id else { return }
            peaks = result
            isLoadingWaveform = false
        }
    }

    private func signedOffset(_ milliseconds: Int) -> String {
        let sign = milliseconds >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.3f", Double(milliseconds) / 1000)) s"
    }

    private func time(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00.000" }
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, seconds)
    }
}

private struct LabWaveform: View {
    let peaks: [CGFloat]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let markerTime: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let centerY = size.height / 2
                let step = size.width / CGFloat(peaks.count)
                let barWidth = max(1, min(3, step * 0.58))
                let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
                let playheadX = CGFloat(progress) * size.width

                for index in peaks.indices {
                    let level = max(0.025, min(1, peaks[index]))
                    let height = max(4, level * size.height * 0.78)
                    let x = (CGFloat(index) + 0.5) * step
                    let rect = CGRect(x: x - barWidth / 2, y: centerY - height / 2, width: barWidth, height: height)
                    let color = x <= playheadX ? USTheme.accent.opacity(0.96) : Color.white.opacity(0.58)
                    context.fill(Path(rect), with: .color(color))
                }

                if duration > 0 {
                    var line = Path()
                    line.move(to: CGPoint(x: playheadX, y: 0))
                    line.addLine(to: CGPoint(x: playheadX, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.95)), lineWidth: 1.4)
                }

                if let markerTime, duration > 0 {
                    let markerProgress = min(1, max(0, markerTime / duration))
                    let markerX = CGFloat(markerProgress) * size.width
                    var markerLine = Path()
                    markerLine.move(to: CGPoint(x: markerX, y: 0))
                    markerLine.addLine(to: CGPoint(x: markerX, y: size.height))
                    context.stroke(markerLine, with: .color(USTheme.accent), lineWidth: 2.2)

                    let markerRect = CGRect(x: markerX - 5, y: 4, width: 10, height: 10)
                    context.fill(Path(ellipseIn: markerRect), with: .color(USTheme.accent))
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        guard duration > 0, proxy.size.width > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / proxy.size.width))
                        onSeek(duration * Double(fraction))
                    }
            )
        }
    }
}

private enum LyricsWaveformAnalyzer {
    static func peaks(for url: URL, targetCount: Int) async -> [CGFloat] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat
                    let totalFrames = Int(file.length)
                    guard totalFrames > 0, format.channelCount > 0 else {
                        continuation.resume(returning: [])
                        return
                    }

                    let count = max(240, targetCount)
                    var values = [Float](repeating: 0, count: count)
                    let capacity: AVAudioFrameCount = 4096
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                        continuation.resume(returning: [])
                        return
                    }

                    var frameBase = 0
                    while frameBase < totalFrames {
                        let requested = AVAudioFrameCount(min(Int(capacity), totalFrames - frameBase))
                        try file.read(into: buffer, frameCount: requested)
                        let frames = Int(buffer.frameLength)
                        guard frames > 0 else { break }

                        if let channels = buffer.floatChannelData {
                            let channelCount = Int(format.channelCount)
                            let sampleStride = max(1, frames / 1024)
                            var sample = 0
                            while sample < frames {
                                var amplitude: Float = 0
                                for channel in 0..<channelCount {
                                    amplitude = max(amplitude, abs(channels[channel][sample]))
                                }
                                let index = min(count - 1, ((frameBase + sample) * count) / totalFrames)
                                values[index] = max(values[index], amplitude)
                                sample += sampleStride
                            }
                        }
                        frameBase += frames
                    }

                    let maximum = max(0.000_001, values.max() ?? 0)
                    continuation.resume(returning: values.map {
                        CGFloat(pow(Double(max(0, min(1, $0 / maximum))), 0.62))
                    })
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
