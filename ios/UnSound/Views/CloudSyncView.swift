import SwiftUI

struct CloudSyncView: View {
    @ObservedObject var cloud: CloudSyncCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        setupCard
                        if let remote = cloud.remotePlayback {
                            remotePlaybackCard(remote)
                        }
                        sharedContentCard
                        limitsCard
                        BrandFooter()
                    }
                    .padding(18)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("SHARED SYNC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(cloud.isConfigured ? Color.green : USTheme.accent)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.text(cloud.isConfigured ? "SHARED SPACE READY" : "NOT CONFIGURED"))
                        .font(.headline)
                    Text(AppLocalization.text(cloud.status))
                        .font(.caption)
                        .foregroundStyle(USTheme.secondary)
                }
                Spacer()
                Image(systemName: "person.2.fill")
                    .font(.title2.bold())
                    .foregroundStyle(cloud.isConfigured ? .green : USTheme.accent)
            }

            if let date = cloud.lastSync {
                Text("\(AppLocalization.text("Last sync")): \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(USTheme.tertiary)
            }

            Button {
                Task { await cloud.syncNow() }
            } label: {
                HStack {
                    if cloud.isSyncing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(AppLocalization.text(cloud.isSyncing ? "SYNCING" : "SYNC NOW"))
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(USPressStyle())
            .disabled(!cloud.isConfigured || cloud.isSyncing)
            .opacity(cloud.isConfigured ? 1 : 0.45)

            Button {
                Task {
                    if cloud.isListeningPartyHost {
                        await cloud.leaveListeningParty()
                    } else {
                        await cloud.startListeningParty()
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: cloud.isListeningPartyHost
                          ? "stop.circle.fill"
                          : "person.2.wave.2.fill")
                    Text(AppLocalization.text(cloud.isListeningPartyHost
                         ? "LEAVE LISTENING PARTY"
                         : (cloud.isListeningPartyFollower
                            ? "TAKE OVER LISTENING PARTY"
                            : "START LISTENING PARTY")))
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .usGlass(
                    RoundedRectangle(cornerRadius: 16, style: .continuous),
                    interactive: true,
                    tint: USTheme.accent.opacity(0.10)
                )
            }
            .buttonStyle(USPressStyle())
            .disabled(!cloud.isConfigured)
            .opacity(cloud.isConfigured ? 1 : 0.45)
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(AppLocalization.text("CONNECT IPHONES"))
                .font(.headline)

            Text(AppLocalization.text("Create a short code on one iPhone. Enter it on the other iPhone once — no links or server addresses."))
                .font(.caption)
                .foregroundStyle(USTheme.secondary)

            Button {
                Task { await cloud.createConnectionCode() }
            } label: {
                Label {
                    Text(AppLocalization.text("GENERATE A CODE"))
                } icon: {
                    Image(systemName: "key.fill")
                }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .usGlass(
                        RoundedRectangle(cornerRadius: 15, style: .continuous),
                        interactive: true,
                        tint: USTheme.accent.opacity(0.08)
                    )
            }
            .buttonStyle(USPressStyle())

            if !cloud.inviteCode.isEmpty {
                Text(cloud.inviteCode)
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .tracking(5)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }

            HStack(spacing: 9) {
                TextField(AppLocalization.text("Enter code"), text: $cloud.joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced).bold())
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 15))

                Button {
                    Task { await cloud.joinConnection() }
                } label: {
                    Text(AppLocalization.text("APPLY"))
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(USPressStyle())
            }
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: USTheme.accent.opacity(0.03))
    }

    private func remotePlaybackCard(_ remote: RemotePlaybackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncImage(url: remote.artworkURL.flatMap { URL(string: $0) }) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "waveform")
                        .foregroundStyle(USTheme.accent)
                }
                .frame(width: 58, height: 58)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(remote.deviceName.uppercased())
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.green)
                    Text(remote.title).font(.headline).lineLimit(1)
                    Text(remote.artist).font(.caption).foregroundStyle(USTheme.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: remote.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.white)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = remote.estimatedPosition(at: context.date)
                VStack(spacing: 5) {
                    ProgressView(value: position, total: max(0.01, remote.duration))
                        .tint(USTheme.accent)
                    HStack {
                        Text(time(position))
                        Spacer()
                        Text(time(remote.duration))
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(USTheme.tertiary)
                }
            }
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var sharedContentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SYNCED")
                .font(.headline)
            row("Song + position when SYNC NOW is pressed", icon: "dot.radiowaves.left.and.right")
            row("Personal libraries stay separate", icon: "music.note.house.fill")
            row("Personal likes + playlists stay separate", icon: "person.2.badge.gearshape")
        }
        .padding(17)
        .usGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.white.opacity(0.012))
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PLAYBACK LINK ONLY", systemImage: "link.circle.fill")
                .font(.subheadline.bold())
            Text("Shared Sync is only for jumping between the current song and playback position. MP3 upload/download lives separately in UnSound Cloud under Settings.")
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
        }
        .padding(15)
        .background(Color.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.055)))
    }

    private func fieldTitle(_ value: String) -> some View {
        Text(AppLocalization.text(value))
            .font(.caption2.bold())
            .foregroundStyle(USTheme.secondary)
    }

    private func row(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(USTheme.accent)
                .frame(width: 24)
            Text(AppLocalization.text(title))
                .font(.caption.weight(.semibold))
            Spacer()
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(.green)
        }
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
