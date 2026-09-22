import SwiftUI

struct SyncLabView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var rawLyrics = ""
    @State private var lines: [String] = []
    @State private var timestamps: [TimeInterval?] = []
    @State private var activeIndex = 0
    @State private var isSyncing = false
    @State private var status: String?
    @State private var originalSpeed: Double?
    @State private var syncSpeed = 1.0

    private let lyricsService = LyricsService()

    private var currentTrack: Track? { audio.currentTrack }
    private var hasLyrics: Bool { !lines.isEmpty }
    private var completedCount: Int { timestamps.compactMap { $0 }.count }
    private var isComplete: Bool { hasLyrics && completedCount == lines.count }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        trackCard
                        inputSection
                        if hasLyrics {
                            progressSection
                            syncWindow(proxy: proxy)
                            controls
                            fineTuneSection
                            saveSection
                        }
                        BrandFooter()
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            originalSpeed = audio.speed
            syncSpeed = min(1, max(0.5, audio.speed))
        }
        .onDisappear {
            if let originalSpeed { audio.speed = originalSpeed }
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
                Text("SYNC LAB")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                Text("Tap NEXT when each new line starts.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
            }
            Spacer()
        }
    }

    private var trackCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.title2.bold())
                .foregroundStyle(USTheme.accent)
                .frame(width: 44, height: 44)
                .usGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: USTheme.accent.opacity(0.08))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack?.title ?? AppLocalization.text("No track playing"))
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(currentTrack?.artist ?? AppLocalization.text("Play a local track first"))
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 40, height: 40)
                    .usGlass(Circle(), interactive: true, tint: USTheme.accent.opacity(0.07))
            }
            .buttonStyle(USPressStyle())
            .disabled(currentTrack == nil)
        }
        .padding(15)
        .usGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LYRICS TEXT")
                    .font(.caption.bold())
                    .tracking(1.3)
                    .foregroundStyle(USTheme.tertiary)
                Spacer()
                if hasLyrics {
                    Button("RESET") { resetSync() }
                        .font(.caption2.bold())
                        .foregroundStyle(USTheme.accent)
                }
            }

            if !hasLyrics {
                TextEditor(text: $rawLyrics)
                    .font(.system(size: 14, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 190)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.07)))

                Button {
                    prepareLines()
                } label: {
                    Label("PREPARE LINES", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(USPressStyle())
                .disabled(rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentTrack == nil)
                .opacity(currentTrack == nil ? 0.45 : 1)
            } else {
                Text("\(lines.count) lines ready. Start playback, then press NEXT exactly when the highlighted line begins.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var progressSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(completedCount) / \(lines.count)")
                    .font(.caption.monospacedDigit().bold())
                Spacer()
                Text(isComplete ? "READY TO SAVE" : "LINE \(min(activeIndex + 1, lines.count))")
                    .font(.caption2.bold())
                    .foregroundStyle(isComplete ? Color.green : USTheme.secondary)
            }

            ProgressView(value: Double(completedCount), total: Double(max(1, lines.count)))
                .tint(USTheme.accent)
        }
        .padding(.horizontal, 4)
    }

    private func syncWindow(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 4) {
            ForEach(lines.indices, id: \.self) { index in
                if abs(index - activeIndex) <= 2 || (isComplete && index >= max(0, lines.count - 3)) {
                    lyricRow(index)
                        .id(index)
                }
            }
        }
        .padding(12)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: USTheme.accent.opacity(0.025))
        .onChange(of: activeIndex) { _, newValue in
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
    }

    private func lyricRow(_ index: Int) -> some View {
        let isActive = !isComplete && index == activeIndex
        let isDone = timestamps.indices.contains(index) && timestamps[index] != nil

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestampLabel(index))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isDone ? USTheme.accent : USTheme.tertiary)
                .frame(width: 54, alignment: .leading)

            Text(lines[index])
                .font(.system(size: isActive ? 21 : 16, weight: isActive ? .bold : .semibold, design: .rounded))
                .foregroundStyle(isActive ? .white : (isDone ? .white.opacity(0.60) : .white.opacity(0.34)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isActive)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isActive ? 13 : 9)
        .background(isActive ? USTheme.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { back() } label: {
                    Label("BACK", systemImage: "arrow.uturn.backward")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)
                }
                .buttonStyle(USPressStyle())
                .disabled(completedCount == 0)

                Button { stampNext() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isComplete ? "checkmark" : "forward.end.fill")
                        Text(AppLocalization.text(isComplete ? "DONE" : "NEXT"))
                    }
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isComplete ? Color.green.opacity(0.8) : USTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(USPressStyle())
                .disabled(isComplete || currentTrack == nil)
            }

            HStack(spacing: 10) {
                Button { audio.seek(to: max(0, audio.currentTime - 2)) } label: {
                    Label("-2 s", systemImage: "gobackward.5")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
                }
                .buttonStyle(USPressStyle())

                Button { audio.toggle() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline.bold())
                        .frame(width: 54, height: 42)
                        .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true, tint: USTheme.accent.opacity(0.08))
                }
                .buttonStyle(USPressStyle())

                Button { audio.seek(to: min(audio.duration, audio.currentTime + 2)) } label: {
                    Label("+2 s", systemImage: "goforward.5")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .usGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), interactive: true)
                }
                .buttonStyle(USPressStyle())
            }
        }
    }

    private var fineTuneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SYNC SPEED")
                    .font(.caption.bold())
                    .tracking(1.2)
                    .foregroundStyle(USTheme.tertiary)
                Spacer()
                Text(String(format: "%.2fx", syncSpeed))
                    .font(.caption.monospacedDigit().bold())
            }

            Slider(value: $syncSpeed, in: 0.5...1.0, step: 0.05)
                .tint(USTheme.accent)
                .onChange(of: syncSpeed) { _, value in audio.speed = value }

            if completedCount > 0 {
                HStack(spacing: 9) {
                    Button { nudgeLast(by: -0.05) } label: {
                        Text("LAST -50 ms")
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .usGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
                    }
                    .buttonStyle(USPressStyle())

                    Button { nudgeLast(by: 0.05) } label: {
                        Text("LAST +50 ms")
                            .font(.caption2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .usGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
                    }
                    .buttonStyle(USPressStyle())
                }
            }
        }
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Color.white.opacity(0.01))
    }

    private var saveSection: some View {
        VStack(spacing: 9) {
            Button { save() } label: {
                Label("SAVE SYNCED LYRICS", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(isComplete ? USTheme.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(USPressStyle())
            .disabled(!isComplete)

            if let status {
                Text(AppLocalization.text(status))
                    .font(.caption)
                    .foregroundStyle(status.contains("Saved") ? Color.green : USTheme.secondary)
            }
        }
    }

    private func prepareLines() {
        let prepared = rawLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !prepared.isEmpty else {
            status = "Paste at least one lyric line."
            return
        }

        lines = prepared
        timestamps = Array(repeating: nil, count: prepared.count)
        activeIndex = 0
        isSyncing = true
        status = "Ready. Start the song and tap NEXT on every line."
    }

    private func stampNext() {
        guard hasLyrics, activeIndex < lines.count else { return }
        timestamps[activeIndex] = max(0, audio.currentTime)
        if activeIndex < lines.count - 1 {
            activeIndex += 1
        } else {
            activeIndex = lines.count
            isSyncing = false
            status = "All lines timed. Fine-tune if needed, then save."
        }
    }

    private func back() {
        guard completedCount > 0 else { return }
        let target = min(max(0, activeIndex - 1), lines.count - 1)
        activeIndex = target
        timestamps[target] = nil
        isSyncing = true
        status = "Line \(target + 1) reopened."
    }

    private func nudgeLast(by delta: TimeInterval) {
        let last = timestamps.lastIndex { $0 != nil }
        guard let index = last, let current = timestamps[index] else { return }
        timestamps[index] = max(0, current + delta)
    }

    private func save() {
        guard let track = currentTrack, isComplete else { return }
        let lrc = zip(lines, timestamps).compactMap { line, timestamp -> String? in
            guard let timestamp else { return nil }
            let totalHundredths = Int((timestamp * 100).rounded())
            let minutes = totalHundredths / 6000
            let seconds = (totalHundredths % 6000) / 100
            let hundredths = totalHundredths % 100
            return String(format: "[%02d:%02d.%02d]%@", minutes, seconds, hundredths, line)
        }.joined(separator: "\n")

        guard lyricsService.saveManualLRC(lrc, title: track.title, artist: track.artist) else {
            status = "Could not save the synced lyrics."
            return
        }

        player.lyricsSyncStatus = "SYNC LAB saved \(lines.count) lines"
        status = "Saved locally for this track."
        Task {
            await player.loadLyrics(track)
        }
    }

    private func resetSync() {
        lines = []
        timestamps = []
        activeIndex = 0
        isSyncing = false
        status = nil
    }

    private func timestampLabel(_ index: Int) -> String {
        guard timestamps.indices.contains(index), let value = timestamps[index] else { return "--:--" }
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}
