import SwiftUI

@main
struct UnSoundApp: App {
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.english.rawValue
    @StateObject private var library: LibraryStore
    @StateObject private var audio: AudioEngine
    @StateObject private var player: PlayerCoordinator
    @StateObject private var search = SearchService()
    @StateObject private var sync = SyncCoordinator()
    @StateObject private var cloud = CloudSyncCoordinator()
    @StateObject private var cloudLibrary = UnSoundCloudCoordinator()

    init() {
        let l = LibraryStore()
        let a = AudioEngine()
        _library = StateObject(wrappedValue: l)
        _audio = StateObject(wrappedValue: a)
        _player = StateObject(wrappedValue: PlayerCoordinator(audio: a, library: l))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                library: library,
                audio: audio,
                player: player,
                search: search,
                sync: sync,
                cloud: cloud,
                cloudLibrary: cloudLibrary
            )
            .environment(\.locale, (AppLanguage(rawValue: appLanguageRaw) ?? .english).locale)
        }
    }
}
