import SwiftUI

struct RootView: View {
    @ObservedObject var library: LibraryStore
    // Spectrum values change frequently. RootView only passes the engine to
    // focused children, so observing it here invalidated the entire pager.
    let audio: AudioEngine
    @ObservedObject var player: PlayerCoordinator
    let search: SearchService
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var cloud: CloudSyncCoordinator
    @ObservedObject var cloudLibrary: UnSoundCloudCoordinator

    @AppStorage("unsound.cloud.endpoint") private var cloudEndpoint = ""
    @AppStorage("unsound.cloud.spaceCode") private var cloudSpaceCode = ""

    @State private var page = 2
    @State private var greeting = true
    @State private var introProgress: CGFloat = 0
    @State private var showDeviceSync = false
    @State private var showCloudSync = false
    @State private var showUnSoundCloud = false
    @State private var duplicateAlertPresented = false

    private var cloudConfigured: Bool {
        let endpoint = cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = cloudSpaceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 8,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    var body: some View {
        ZStack {
            mainApp
                .scaleEffect(greeting ? (0.105 + 0.895 * introProgress) : 1)
                .allowsHitTesting(!greeting)
                .animation(.easeInOut(duration: 0.98), value: introProgress)

            if greeting {
                GreetingView(portalProgress: $introProgress) {
                    page = 2
                    withAnimation(.easeOut(duration: 0.08)) {
                        greeting = false
                    }
                }
                .zIndex(100)
            }
        }
        .background(USTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // Windows link also owns the persistent per-device audio settings,
            // so keep it attached for bass/speed/effect persistence. Its network
            // tick returns immediately while not paired.
            sync.attach(audio: audio, library: library, player: player)
            cloud.attach(library: library, player: player, audio: audio)
            cloudLibrary.attach(library: library)
            duplicateAlertPresented = library.currentDuplicateImport != nil
        }
        .onChange(of: library.currentDuplicateImport?.id) { _, id in
            if id != nil { duplicateAlertPresented = true }
        }
        .alert(AppLocalization.text("DUPLICATE FILE"), isPresented: $duplicateAlertPresented) {
            Button(AppLocalization.text("SKIP"), role: .cancel) {
                library.denyCurrentDuplicate()
                presentNextDuplicateIfNeeded()
            }

            if library.duplicateImportQueue.count > 1 {
                Button("\(AppLocalization.text("SKIP ALL")) (\(library.duplicateImportQueue.count))", role: .destructive) {
                    _ = library.skipAllDuplicateImports()
                    duplicateAlertPresented = false
                }
            }

            Button(AppLocalization.text("SAVE")) {
                _ = library.acceptCurrentDuplicate()
                presentNextDuplicateIfNeeded()
            }
        } message: {
            if let duplicate = library.currentDuplicateImport {
                Text("\(duplicate.displayName) is already in UnSound as \"\(duplicate.existingTitle)\". Import a second copy anyway?")
            }
        }
        .sheet(isPresented: $showDeviceSync) {
            DeviceSyncView(sync: sync)
        }
        .sheet(isPresented: $showCloudSync) {
            CloudSyncSessionView(cloud: cloud)
        }
        .sheet(isPresented: $showUnSoundCloud) {
            UnSoundCloudView(cloud: cloudLibrary)
        }
        .fullScreenCover(isPresented: $player.showFullPlayer) {
            FullPlayerView(player: player, audio: audio, library: library)
        }
        .fullScreenCover(isPresented: lyricsPresentation) {
            FullLyricsView(player: player, audio: audio)
        }
    }

    private func presentNextDuplicateIfNeeded() {
        duplicateAlertPresented = false
        Task { @MainActor in
            await Task.yield()
            duplicateAlertPresented = library.currentDuplicateImport != nil
        }
    }

    private var mainApp: some View {
        TabView(selection: $page) {
            SearchView(search: search, library: library, player: player).tag(0)
            LibraryView(library: library, player: player).tag(1)
            NowPlayingView(player: player, audio: audio, library: library).tag(2)
            ReplayView(library: library).tag(3)
            settingsPage.tag(4)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(USTheme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                BottomNavigationView(page: $page)
                    .padding(.horizontal, 14)
                    .padding(.top, 7)
                    .padding(.bottom, 6)
            }
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.94), Color.black.opacity(0.58), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )
            .zIndex(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomPlayer(player: player, audio: audio, library: library, sync: sync)
                .background(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.52), Color.black.opacity(0.90)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
        }
    }

    private var lyricsPresentation: Binding<Bool> {
        Binding(
            get: { player.showLyrics && !player.showFullPlayer },
            set: { presented in
                if !presented { player.showLyrics = false }
            }
        )
    }

    private var settingsPage: some View {
        SettingsView(
            library: library,
            audio: audio,
            pcSyncConnected: sync.isPaired,
            sharedSyncConnected: cloudConfigured,
            downloadsConnected: cloudLibrary.isConfigured,
            openPCSync: { showDeviceSync = true },
            openSharedSync: { showCloudSync = true },
            openDownloads: { showUnSoundCloud = true }
        )
    }
}
