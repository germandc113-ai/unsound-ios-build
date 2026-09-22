import SwiftUI
import UIKit

struct ArtworkCropView: View {
    let image: UIImage
    let onUse: (Data) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { proxy in
                    let side = min(proxy.size.width - 36, 380)

                    VStack(spacing: 18) {
                        Spacer(minLength: 18)

                        cropCanvas(side: side)

                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("CROP ARTWORK")
                                    .font(.caption.bold())
                                    .tracking(1.4)
                                Spacer()
                                Text(String(format: "%.1fx", zoom))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(USTheme.secondary)
                            }

                            Slider(value: $zoom, in: 1...4, step: 0.01)
                                .tint(USTheme.accent)
                                .onChange(of: zoom) { _, _ in
                                    offset = clampedOffset(offset, side: side)
                                }

                            Text("Drag the image to position it. UnSound artwork is saved as a square so it fits the player, playlists and iOS Now Playing cleanly.")
                                .font(.caption)
                                .foregroundStyle(USTheme.secondary)
                        }
                        .padding(.horizontal, 20)

                        Button {
                            guard let data = croppedJPEG(side: side) else { return }
                            onUse(data)
                            dismiss()
                        } label: {
                            Text("USE CROP")
                                .font(.headline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(USTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(USPressStyle())
                        .padding(.horizontal, 20)

                        Spacer(minLength: 16)
                    }
                }
            }
            .navigationTitle("Crop Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cropCanvas(side: CGFloat) -> some View {
        let fitted = fittedSize(side: side)
        let effectiveOffset = clampedOffset(offset, side: side)

        return ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(zoom)
                .offset(effectiveOffset)
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.82), lineWidth: 1.2)
        )
        .overlay {
            cropGrid
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let proposed = CGSize(
                        width: dragStart.width + value.translation.width,
                        height: dragStart.height + value.translation.height
                    )
                    offset = clampedOffset(proposed, side: side)
                }
                .onEnded { _ in
                    offset = clampedOffset(offset, side: side)
                    dragStart = offset
                }
        )
        .onAppear {
            dragStart = offset
        }
    }

    private var cropGrid: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: w * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: w * 2 / 3, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: h * 2 / 3))
                path.addLine(to: CGPoint(x: w, y: h * 2 / 3))
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }

    private func fittedSize(side: CGFloat) -> CGSize {
        guard let cg = image.cgImage else { return CGSize(width: side, height: side) }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return CGSize(width: side, height: side) }

        let scale = max(side / width, side / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    private func clampedOffset(_ proposed: CGSize, side: CGFloat) -> CGSize {
        let fitted = fittedSize(side: side)
        let displayedWidth = fitted.width * zoom
        let displayedHeight = fitted.height * zoom
        let maxX = max(0, (displayedWidth - side) / 2)
        let maxY = max(0, (displayedHeight - side) / 2)

        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }

    private func croppedJPEG(side: CGFloat) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let pixelWidth = CGFloat(cg.width)
        let pixelHeight = CGFloat(cg.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let baseScale = max(side / pixelWidth, side / pixelHeight)
        let totalScale = baseScale * zoom
        let fittedOffset = clampedOffset(offset, side: side)
        let displayedWidth = pixelWidth * totalScale
        let displayedHeight = pixelHeight * totalScale
        let left = (side - displayedWidth) / 2 + fittedOffset.width
        let top = (side - displayedHeight) / 2 + fittedOffset.height

        var rect = CGRect(
            x: -left / totalScale,
            y: -top / totalScale,
            width: side / totalScale,
            height: side / totalScale
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).integral
        guard rect.width > 2, rect.height > 2, let cropped = cg.cropping(to: rect) else { return nil }

        let output = UIImage(cgImage: cropped, scale: 1, orientation: .up)
        return output.jpegData(compressionQuality: 0.92)
    }
}
