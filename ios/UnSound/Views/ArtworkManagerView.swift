import SwiftUI
import PhotosUI
import UIKit

private enum ArtworkLayoutMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

private struct ArtworkCropCandidate: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ArtworkManagerView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var audio: AudioEngine

    @State private var selectedIDs: Set<UUID> = []
    @State private var query = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var pendingArtwork: Data?
    @State private var status: String?
    @State private var layoutMode: ArtworkLayoutMode = .list
    @State private var cropCandidate: ArtworkCropCandidate?

    private let applyAnchor = "artwork-apply-anchor"

    private var visibleTracks: [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.artist.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var visibleIDs: Set<UUID> {
        Set(visibleTracks.map(\.id))
    }

    private var visibleSelectedCount: Int {
        selectedIDs.intersection(visibleIDs).count
    }

    private var allVisibleSelected: Bool {
        !visibleTracks.isEmpty && visibleSelectedCount == visibleTracks.count
    }

    private var selectAllIcon: String {
        if allVisibleSelected { return "checkmark.circle.fill" }
        if visibleSelectedCount > 0 { return "circle.lefthalf.filled" }
        return "circle"
    }

    var body: some View {
        ZStack {
            USBackdrop()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("CUSTOM ARTWORK")
                            .font(.system(size: 28, weight: .black))
                            .fontWidth(.condensed)

                        Text("Choose one or many songs, then apply the same square cover. Non-square images open a crop screen first.")
                            .font(.subheadline)
                            .foregroundStyle(USTheme.secondary)

                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(USTheme.secondary)
                            TextField("Search songs", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(USTheme.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)

                        if layoutMode == .list {
                            listSelection
                        } else {
                            gridSelection
                        }

                        VStack(spacing: 14) {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label(pendingArtwork == nil ? "CHOOSE IMAGE" : "CHANGE IMAGE", systemImage: "photo.badge.plus")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .usGlass(RoundedRectangle(cornerRadius: 19, style: .continuous), interactive: true, tint: USTheme.accent.opacity(0.08))
                            }
                            .buttonStyle(USPressStyle())
                            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)

                            if let data = pendingArtwork, let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(USTheme.hairline))
                            }

                            Button {
                                applyArtwork()
                            } label: {
                                Text("APPLY TO \(selectedIDs.count) SONG\(selectedIDs.count == 1 ? "" : "S")")
                                    .font(.headline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                                    .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(USPressStyle())
                            .disabled(selectedIDs.isEmpty || pendingArtwork == nil)
                            .opacity(selectedIDs.isEmpty || pendingArtwork == nil ? 0.38 : 1)

                            Button(role: .destructive) {
                                removeArtwork()
                            } label: {
                                Text("REMOVE CUSTOM ARTWORK")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .usGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), interactive: true)
                            }
                            .buttonStyle(USPressStyle())
                            .disabled(selectedIDs.isEmpty)
                        }
                        .id(applyAnchor)

                        if let status {
                            Text(AppLocalization.text(status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(USTheme.secondary)
                        }

                        BrandFooter().padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .top, spacing: 8) {
                    selectorToolbar(proxy: proxy)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0.94), Color.black.opacity(0.68), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        }
        .navigationTitle("Artwork Manager")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let rawImage = UIImage(data: data) else {
                    await MainActor.run { status = "Could not read that image." }
                    return
                }

                let image = normalizedImage(rawImage)
                let width = image.cgImage.map { CGFloat($0.width) } ?? image.size.width
                let height = image.cgImage.map { CGFloat($0.height) } ?? image.size.height
                let ratio = height > 0 ? width / height : 1

                await MainActor.run {
                    if abs(ratio - 1) > 0.02 {
                        cropCandidate = ArtworkCropCandidate(image: image)
                        status = "Crop the image to UnSound's square artwork format."
                    } else if let jpeg = image.jpegData(compressionQuality: 0.92) {
                        pendingArtwork = jpeg
                        status = nil
                    } else {
                        status = "Could not prepare that image."
                    }
                }
            }
        }
        .sheet(item: $cropCandidate) { candidate in
            ArtworkCropView(
                image: candidate.image,
                onUse: { data in
                    pendingArtwork = data
                    status = "Crop ready."
                    cropCandidate = nil
                },
                onCancel: {
                    cropCandidate = nil
                }
            )
        }
    }

    private func selectorToolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleAllVisible()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectAllIcon)
                    Text(AppLocalization.text(allVisibleSelected ? "DESELECT" : "SELECT ALL"))
                }
                .font(.system(size: 10, weight: .black, design: .rounded))
                .padding(.horizontal, 11)
                .frame(height: 40)
                .usGlass(Capsule(), interactive: true, tint: allVisibleSelected ? USTheme.accent.opacity(0.13) : nil)
            }
            .buttonStyle(USPressStyle())
            .disabled(visibleTracks.isEmpty)

            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo(applyAnchor, anchor: .center)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.to.line.compact")
                    Text("GO TO APPLY")
                }
                .font(.system(size: 10, weight: .black, design: .rounded))
                .padding(.horizontal, 11)
                .frame(height: 40)
                .usGlass(Capsule(), interactive: true, tint: selectedIDs.isEmpty ? nil : USTheme.accent.opacity(0.09))
            }
            .buttonStyle(USPressStyle())

            Spacer(minLength: 2)

            HStack(spacing: 2) {
                ForEach(ArtworkLayoutMode.allCases) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            layoutMode = mode
                        }
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(
                                layoutMode == mode ? Color.white.opacity(0.09) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(USPressStyle())
                    .accessibilityLabel(mode == .list ? "List" : "Grid")
                }
            }
            .padding(4)
            .usGlass(RoundedRectangle(cornerRadius: 13, style: .continuous), interactive: true)
        }
    }

    private var listSelection: some View {
        VStack(spacing: 7) {
            ForEach(visibleTracks) { track in
                Button {
                    toggle(track.id)
                } label: {
                    HStack(spacing: 12) {
                        artworkThumb(track, size: 48)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.headline).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(USTheme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedIDs.contains(track.id) ? USTheme.accent : .white.opacity(0.28))
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(USTheme.hairline))
                }
                .buttonStyle(USPressStyle())
            }
        }
    }

    private var gridSelection: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(visibleTracks) { track in
                Button {
                    toggle(track.id)
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        ZStack(alignment: .topTrailing) {
                            artworkThumb(track, size: 142)
                                .frame(maxWidth: .infinity)

                            Image(systemName: selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedIDs.contains(track.id) ? USTheme.accent : .white.opacity(0.72))
                                .padding(8)
                                .shadow(color: .black.opacity(0.8), radius: 5)
                        }

                        Text(track.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(USTheme.secondary)
                            .lineLimit(1)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selectedIDs.contains(track.id) ? USTheme.accent.opacity(0.09) : Color.black.opacity(0.42),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(selectedIDs.contains(track.id) ? USTheme.accent.opacity(0.45) : USTheme.hairline)
                    )
                }
                .buttonStyle(USPressStyle())
            }
        }
    }

    @ViewBuilder
    private func artworkThumb(_ track: Track, size: CGFloat) -> some View {
        if let url = library.customArtworkURL(for: track), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 16 : 12, style: .continuous))
        } else if let artworkURL = track.artworkURL, let url = URL(string: artworkURL) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder(size)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 16 : 12, style: .continuous))
        } else {
            artworkPlaceholder(size)
        }
    }

    private func artworkPlaceholder(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size > 60 ? 16 : 12, style: .continuous)
            .fill(USTheme.accent.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "music.note").foregroundStyle(USTheme.accent))
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleAllVisible() {
        if allVisibleSelected {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    private func applyArtwork() {
        guard let pendingArtwork else { return }
        do {
            let changed = try library.applyCustomArtwork(pendingArtwork, to: selectedIDs)
            if let current = audio.currentTrack,
               let refreshed = changed.first(where: { $0.id == current.id }) {
                audio.updateSystemArtwork(for: refreshed)
            }
            status = "Artwork applied to \(changed.count) song\(changed.count == 1 ? "" : "s")."
        } catch {
            status = "Artwork failed: \(error.localizedDescription)"
        }
    }

    private func removeArtwork() {
        let changed = library.removeCustomArtwork(from: selectedIDs)
        if let current = audio.currentTrack,
           let refreshed = changed.first(where: { $0.id == current.id }) {
            audio.updateSystemArtwork(for: refreshed)
        }
        status = "Custom artwork removed from \(changed.count) song\(changed.count == 1 ? "" : "s")."
    }

    private func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
