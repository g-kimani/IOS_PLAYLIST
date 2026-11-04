import SwiftUI

struct ActivePlayer: Identifiable {
    let id: UUID // session id
}

/// Owns the one active player so playback can outlive the full-screen player screen
/// (needed for Picture in Picture).
final class PlayerCoordinator: ObservableObject {
    @Published var active: ActivePlayer?      // drives the full-screen cover
    private(set) var model: PlayerModel?
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func play(_ sessionID: UUID) {
        if let existing = model, existing.sessionID == sessionID {
            existing.syncToSession()          // keeps playing if it's already on the right video
        } else {
            model?.shutdown()
            let m = PlayerModel(sessionID: sessionID, store: store)
            m.onPiPWillStart = { [weak self] in self?.active = nil }
            m.onPiPRestore = { [weak self] in self?.active = ActivePlayer(id: sessionID) }
            m.onPiPStopped = { [weak self] in self?.pipStopped() }
            m.onQueueEmptied = { [weak self] in self?.close() }
            model = m
        }
        active = ActivePlayer(id: sessionID)
    }

    func close() {
        active = nil
    }

    /// Called whenever the full-screen player goes away.
    func coverDismissed() {
        guard let m = model else { return }
        if m.keepAliveForPiP { return }       // video carries on in the PiP window
        m.shutdown()
        model = nil
    }

    private func pipStopped() {
        // The PiP window was closed (not expanded back into the app).
        if active == nil {
            model?.shutdown()
            model = nil
        }
    }
}

@main
struct VideoPlaylistApp: App {
    @StateObject private var store: SessionStore
    @StateObject private var coordinator: PlayerCoordinator

    init() {
        let s = SessionStore()
        _store = StateObject(wrappedValue: s)
        _coordinator = StateObject(wrappedValue: PlayerCoordinator(store: s))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(coordinator)
                .fullScreenCover(item: $coordinator.active) { _ in
                    Group {
                        if let model = coordinator.model {
                            PlayerView(model: model)
                        } else {
                            Color.black.ignoresSafeArea()
                        }
                    }
                    .environmentObject(store)
                    .environmentObject(coordinator)
                }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
