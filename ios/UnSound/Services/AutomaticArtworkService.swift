import Foundation
import AVFoundation

enum AutomaticArtworkService {
    static func artworkData(
        for audioURL: URL,
        fallbackArtworkURL: String?
    ) async -> Data? {
        if let embedded = await embeddedArtworkData(from: audioURL) {
            return embedded
        }

        guard let rawURL = fallbackArtworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .returnCacheDataElseLoad

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data.count > 256 ? data : nil
        } catch {
            return nil
        }
    }

    private static func embeddedArtworkData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let artworkItems = AVMetadataItem.metadataItems(
                from: commonMetadata,
                filteredByIdentifier: .commonIdentifierArtwork
            )

            for item in artworkItems {
                if let data = try await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            }
        } catch {
            // Missing or unreadable artwork must never make an audio import fail.
        }

        return nil
    }
}
