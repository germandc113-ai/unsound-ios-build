import SwiftUI
import UIKit

struct TrackHeroArtwork: View {
    let track: Track
    @ObservedObject var audio: AudioEngine
    @ObservedObject var library: LibraryStore
    var cornerRadius: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [USTheme.accentDeep.opacity(0.72), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            customOrRemoteArtwork

            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.black.opacity(0.24), Color.black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            VStack(spacing: 18) {
                Spacer()

                ReactiveSpectrumIcon(
                    spectrum: audio.visualSpectrum,
                    size: 86,
                    reducedVisuals: audio.performanceLimited
                )

                Text(track.title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.white)
                    .shadow(
                        color: audio.performanceLimited ? .clear : .black.opacity(0.8),
                        radius: audio.performanceLimited ? 0 : 8,
                        y: audio.performanceLimited ? 0 : 3
                    )
                    .padding(.horizontal, 22)

                Spacer()

                HStack {
                    Text("UNSOUND")
                        .font(.caption2.bold())
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Image(systemName: "waveform")
                        .foregroundStyle(USTheme.accent)
                }
                .padding(18)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.075)))
        .shadow(
            color: audio.performanceLimited ? .clear : .black.opacity(0.52),
            radius: audio.performanceLimited ? 0 : 28,
            y: audio.performanceLimited ? 0 : 14
        )
    }

    @ViewBuilder
    private var customOrRemoteArtwork: some View {
        if let image = library.customArtworkImage(for: track) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if let artworkURL = track.artworkURL,
                  let url = URL(string: artworkURL) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
