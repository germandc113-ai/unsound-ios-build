import SwiftUI

struct CloudSyncSessionView: View {
    @ObservedObject var cloud: CloudSyncCoordinator

    var body: some View {
        CloudSyncView(cloud: cloud)
    }
}
