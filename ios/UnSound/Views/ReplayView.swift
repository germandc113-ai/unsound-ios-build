import SwiftUI

struct ReplayView: View {
    @ObservedObject var library: LibraryStore
    @State private var period: ReplayPeriod = .week
    @State private var refreshToken = UUID()

    private var summary: ReplaySummary {
        _ = refreshToken
        return ReplayHistory.summary(for: period)
    }

    private var daily: [(String, Double)] {
        _ = refreshToken
        return ReplayHistory.dailyMinutes(for: period)
    }

    private var topTracks: [(Track, Double, Int)] {
        summary.secondsByTrack
            .sorted { $0.value > $1.value }
            .prefix(8)
            .compactMap { id, seconds in
                guard let track = library.track(id) else { return nil }
                return (track, seconds, summary.playsByTrack[id, default: 0])
            }
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UNSOUND REPLAY")
                            .font(.system(size: 31, weight: .black))
                            .fontWidth(.condensed)
                            .tracking(0.5)
                        Text("Your listening flow, bass habits and top tracks.")
                            .font(.subheadline)
                            .foregroundStyle(USTheme.secondary)
                    }

                    periodPicker
                    headlineCard
                    statsGrid
                    timelineCard
                    topTracksCard
                    BrandFooter().padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.top, 82)
                .padding(.bottom, 116)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { refreshToken = UUID() }
        .onChange(of: period) { _, _ in refreshToken = UUID() }
    }

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(ReplayPeriod.allCases) { value in
                Button {
                    withAnimation(.snappy(duration: 0.20)) { period = value }
                } label: {
                    Text(value.rawValue)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(period == value ? .white : .white.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(period == value ? Color.white.opacity(0.09) : Color.clear, in: Capsule())
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(5)
        .usGlass(Capsule(), interactive: true, tint: Color.black.opacity(0.18))
    }

    private var headlineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LISTENING TIME")
                .font(.caption2.bold())
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.50))
            Text("\(Int(summary.seconds / 60)) min")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .minimumScaleFactor(0.7)
            Text(periodDescription)
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [USTheme.accentDeep.opacity(0.72), Color.black.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.07)))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            statCard("PLAYS", "\(summary.plays)", "play.fill")
            statCard("TRACKS", "\(summary.uniqueTracks)", "music.note")
            statCard("AVG BASS", String(format: "+%.1f dB", summary.averageBass), "waveform")
            statCard("LIKED", "\(library.likedTracks.count)", "heart.fill")
        }
    }

    private func statCard(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(USTheme.accent)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption2.bold())
                .tracking(1.3)
                .foregroundStyle(USTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .usGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LISTENING FLOW")
                .font(.caption.bold())
                .tracking(1.5)
                .foregroundStyle(USTheme.tertiary)

            if daily.isEmpty {
                Text("Listening history for this period starts building from this version onward.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
                    .padding(.vertical, 18)
            } else {
                let maxMinutes = max(1, daily.map { $0.1 }.max() ?? 1)
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(Array(daily.enumerated()), id: \.offset) { _, item in
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(USTheme.accent.opacity(0.85))
                                    .frame(width: 13, height: max(4, CGFloat(item.1 / maxMinutes) * 82))
                                Text(dayLabel(item.0))
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .foregroundStyle(USTheme.tertiary)
                            }
                        }
                    }
                    .frame(minHeight: 104, alignment: .bottom)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(18)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private var topTracksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TOP TRACKS")
                .font(.caption.bold())
                .tracking(1.5)
                .foregroundStyle(USTheme.tertiary)

            if topTracks.isEmpty {
                Text("No tracked listening time in this period yet.")
                    .font(.caption)
                    .foregroundStyle(USTheme.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(topTracks.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(USTheme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0.title).font(.headline).lineLimit(1)
                            Text("\(item.0.artist) • \(Int(item.1 / 60)) min • \(item.2) plays")
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(18)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.06)))
    }

    private var periodDescription: String {
        switch period {
        case .day: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last 365 days"
        }
    }

    private func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(parts[2])/\(parts[1])"
    }
}
