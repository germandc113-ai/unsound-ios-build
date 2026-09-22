import SwiftUI

struct FullLyricsView: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showLyricsLab = false
    @State private var showSyncLab = false

    var activeIndex: Int? {
        guard !player.lyrics.isEmpty else { return nil }
        return player.lyrics.lastIndex(where: { $0.time <= audio.currentTime })
    }

    var body: some View {
        ZStack {
            USTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                syncBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if player.lyrics.isEmpty {
                                emptyState
                            }

                            ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { idx, line in
                                Button { audio.seek(to: line.time) } label: {
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(
                                            size: idx == activeIndex ? 30 : 24,
                                            weight: idx == activeIndex ? .bold : .semibold,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(idx == activeIndex ? .white : .white.opacity(0.34))
                                        .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 120)
                    }
                    .onChange(of: activeIndex) { _, i in
                        if let i, player.lyrics.indices.contains(i) {
                            withAnimation(.easeOut(duration: 0.24)) {
                                proxy.scrollTo(player.lyrics[i].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showLyricsLab) {
            LyricsLabView(player: player, audio: audio)
        }
        .fullScreenCover(isPresented: $showSyncLab) {
            SyncLabView(player: player, audio: audio)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(USTheme.panel2)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "waveform").foregroundStyle(USTheme.accent))

            VStack(alignment: .leading) {
                Text(audio.currentTrack?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(audio.currentTrack?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }

            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No synced lyrics found.")
                .font(.title2.bold())
                .foregroundStyle(USTheme.secondary)

            Text("FIND LYRICS is the automatic matcher. Use LYRICS LAB to search and offset existing synced lyrics, or SYNC LAB to build timing line-by-line for unreleased/local tracks.")
                .font(.caption)
                .foregroundStyle(USTheme.tertiary)
        }
        .padding(.top, 70)
    }

    private var syncBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    Task {
                        if player.lyrics.isEmpty {
                            await player.retryLyricsLookup()
                        } else {
                            await player.autoSyncLyrics(force: true)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if player.isLyricsSyncing {
                            ProgressView().tint(.white).scaleEffect(0.82)
                        } else {
                            Image(systemName: player.lyrics.isEmpty ? "magnifyingglass" : "wand.and.stars")
                        }
                        Text(
                            player.isLyricsSyncing
                                ? "WORKING"
                                : (player.lyrics.isEmpty ? "FIND" : "AUTO")
                        )
                    }
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .usGlass(
                        RoundedRectangle(cornerRadius: 15, style: .continuous),
                        interactive: true,
                        tint: USTheme.accent.opacity(0.14)
                    )
                }
                .buttonStyle(USPressStyle())
                .disabled(player.isLyricsSyncing)

                Button {
                    showLyricsLab = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                        Text("LYRICS LAB")
                    }
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .usGlass(
                        RoundedRectangle(cornerRadius: 15, style: .continuous),
                        interactive: true,
                        tint: Color.white.opacity(0.025)
                    )
                }
                .buttonStyle(USPressStyle())

                Button {
                    showSyncLab = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        Text("SYNC LAB")
                    }
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .usGlass(
                        RoundedRectangle(cornerRadius: 15, style: .continuous),
                        interactive: true,
                        tint: USTheme.accent.opacity(0.055)
                    )
                }
                .buttonStyle(USPressStyle())
                .disabled(audio.currentTrack == nil)

                Button {
                    player.resetLyricsOffset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 40, height: 40)
                        .usGlass(Circle(), interactive: true)
                }
                .buttonStyle(USPressStyle())
                .disabled(player.lyrics.isEmpty)
            }

            HStack {
                let ms = player.currentLyricsOffsetMs
                Text("OFFSET  \(ms >= 0 ? "+" : "")\(String(format: "%.3f", Double(ms) / 1000.0)) s")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(USTheme.tertiary)

                Spacer()

                if let status = player.lyricsSyncStatus {
                    Text(AppLocalization.text(status))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(USTheme.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
