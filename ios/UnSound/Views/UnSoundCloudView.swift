import SwiftUI

struct UnSoundCloudView: View {
    @ObservedObject var cloud: UnSoundCloudCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showSongPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                USBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerCard
                        actionCard

                        infoCard
                        BrandFooter()
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("UNSOUND CLOUD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
            Button(AppLocalization.text("Done")) { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(cloud.isWorking)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await cloud.refresh()
        }
        .sheet(isPresented: $showSongPicker) {
            DownloadSongPicker(cloud: cloud)
        }
        .alert(
            AppLocalization.text("DUPLICATE FILE"),
            isPresented: Binding(
                get: { cloud.duplicatePrompt != nil },
                set: { presented in
                    if !presented, cloud.duplicatePrompt != nil {
                        cloud.skipCurrentDuplicate()
                    }
                }
            )
        ) {
            Button(AppLocalization.text("SKIP"), role: .cancel) {
                cloud.skipCurrentDuplicate()
            }
            Button(AppLocalization.text("SKIP ALL"), role: .destructive) {
                cloud.skipAllCurrentDuplicates()
            }
            Button(AppLocalization.text("SAVE")) {
                cloud.saveCurrentDuplicate()
            }
        } message: {
            if let duplicate = cloud.duplicatePrompt {
                Text("\(duplicate.title) by \(duplicate.artist) is already in UnSound. Save a second copy?")
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: cloud.isConfigured ? "icloud.fill" : "icloud.slash.fill")
                    .font(.title2.bold())
                    .foregroundStyle(cloud.isConfigured ? .green : USTheme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text(cloud.status))
                        .font(.headline)
                    Text(AppLocalization.text(cloud.detail))
                        .font(.caption)
                        .foregroundStyle(USTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if cloud.cloudFileCount > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("\(cloud.cloudFileCount) FILE\(cloud.cloudFileCount == 1 ? "" : "S") READY")
                }
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.green)
            }

            if cloud.isWorking {
                ProgressView(value: cloud.progress)
                    .tint(USTheme.accent)
            }
        }
        .padding(17)
        .usGlass(
            RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: Color.white.opacity(0.012)
        )
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(AppLocalization.text("DOWNLOAD SONGS"))
                .font(.headline)

            Text(AppLocalization.text("Imported MP3s upload automatically. Download them here at any time, even when the other iPhone is offline."))
                .font(.caption)
                .foregroundStyle(USTheme.secondary)

            VStack(spacing: 10) {
                Button {
                    Task { await cloud.downloadNow() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(AppLocalization.text("DOWNLOAD ALL FILES"))
                    }
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        USTheme.accent,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(USPressStyle())
                .disabled(!cloud.isConfigured || cloud.isWorking)
                .opacity(cloud.isConfigured && !cloud.isWorking ? 1 : 0.42)

                Button {
                    showSongPicker = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "checklist")
                        Text(AppLocalization.text("DOWNLOAD CERTAIN FILES"))
                    }
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .usGlass(
                        RoundedRectangle(cornerRadius: 18, style: .continuous),
                        interactive: true,
                        tint: USTheme.accent.opacity(0.08)
                    )
                }
                .buttonStyle(USPressStyle())
                .disabled(!cloud.isConfigured || cloud.isWorking)
                .opacity(cloud.isConfigured && !cloud.isWorking ? 1 : 0.42)
            }
        }
        .padding(17)
        .usGlass(
            RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: USTheme.accent.opacity(0.025)
        )
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("HOW IT WORKS", systemImage: "bolt.horizontal.icloud.fill")
                .font(.subheadline.bold())

            row(AppLocalization.text("New imports upload automatically"))
            row("Exact duplicate files are ignored by SHA-256")
            row(AppLocalization.text("Downloads remain available while the other phone is offline"))
            row(AppLocalization.text("Choose every file or search and select individual songs"))
        }
        .padding(16)
        .background(
            Color.black.opacity(0.38),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.055))
        )
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(USTheme.secondary)
        }
    }
}

private struct DownloadSongPicker: View {
    @ObservedObject var cloud: UnSoundCloudCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = Set<String>()

    private var filteredSongs: [UnSoundCloudSong] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return cloud.availableSongs }
        return cloud.availableSongs.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.artist.localizedCaseInsensitiveContains(needle)
                || "\($0.title).\($0.fileExtension)".localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredSongs) { song in
                Button {
                    if selection.contains(song.id) {
                        selection.remove(song.id)
                    } else {
                        selection.insert(song.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: song.artworkURL.flatMap { URL(string: $0) }) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "waveform")
                                .foregroundStyle(USTheme.accent)
                        }
                        .frame(width: 46, height: 46)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.subheadline.bold()).lineLimit(1)
                            Text(song.artist).font(.caption).foregroundStyle(USTheme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(song.id) ? USTheme.accent : USTheme.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: Text(AppLocalization.text("Search title, artist or filename")))
            .navigationTitle(AppLocalization.text("DOWNLOAD CERTAIN FILES"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(AppLocalization.text("Download")) (\(selection.count))") {
                        let ids = selection
                        dismiss()
                        Task { await cloud.downloadSelected(ids) }
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
