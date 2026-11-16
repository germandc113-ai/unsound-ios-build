import SwiftUI

struct PlaybackQueueButton: View {
    @ObservedObject var player: PlayerCoordinator
    @ObservedObject var library: LibraryStore
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label(AppLocalization.text("Queue") + " (\(player.queue.count))", systemImage: "list.bullet")
        }
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                List(player.queue, id: \.self) { id in
                    if let track = library.track(id) {
                        Button {
                            player.play(track)
                        } label: {
                            TrackRow(track: track)
                        }
                    }
                }
                .navigationTitle(AppLocalization.text("Queue"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppLocalization.text("Done")) { isPresented = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
