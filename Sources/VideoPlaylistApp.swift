import SwiftUI

struct ActivePlayer: Identifiable {
    let id: UUID // session id
}

final class PlayerCoordinator: ObservableObject {
    @Published var active: ActivePlayer?

    func play(_ sessionID: UUID) {
        active = ActivePlayer(id: sessionID)
    }
}

@main
struct VideoPlaylistApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var coordinator = PlayerCoordinator()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(coordinator)
                .fullScreenCover(item: $coordinator.active) { active in
                    PlayerView(sessionID: active.id, store: store)
                        .environmentObject(store)
                        .environmentObject(coordinator)
                }
        }
    }
}
