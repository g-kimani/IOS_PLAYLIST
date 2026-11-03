import AVFoundation
import Combine
import Foundation

final class PlayerModel: ObservableObject {
    let sessionID: UUID
    let store: SessionStore
    let player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1.0
    @Published var errorText: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?
    private var accessedURLs: [URL] = []

    init(sessionID: UUID, store: SessionStore) {
        self.sessionID = sessionID
        self.store = store

        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }

        // Keeps the play/pause icon in sync even while paused.
        statusCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status != .paused)
            }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.next()
        }

        loadCurrent()
    }

    deinit {
        if let timeObserver = timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver = endObserver { NotificationCenter.default.removeObserver(endObserver) }
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        player.pause()
    }

    private var session: Session? { store.session(sessionID) }

    func loadCurrent(autoplay: Bool = true) {
        // Every new item starts at normal speed.
        rate = 1.0
        player.defaultRate = 1.0
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = []
        errorText = nil
        currentTime = 0
        duration = 0

        guard let session = session, session.queue.indices.contains(session.position) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = session.queue[session.position]

        guard let resolved = FileResolver.resolve(item, store: store) else {
            player.replaceCurrentItem(with: nil)
            errorText = "Can't open \(item.name). The file may have been moved or deleted."
            return
        }
        accessedURLs = resolved.scopedURLs
        if let fresh = resolved.refreshedBookmark {
            store.updateBookmark(fresh, itemID: item.id, in: sessionID)
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: resolved.url))
        if autoplay { play() }
    }

    func play() {
        player.defaultRate = rate
        player.play()
    }

    func togglePlay() {
        if player.timeControlStatus == .paused { play() } else { player.pause() }
    }

    func next() {
        guard let s = session else { return }
        if s.position + 1 < s.queue.count {
            store.setPosition(s.position + 1, for: sessionID)
            loadCurrent()
        } else {
            player.pause()
        }
    }

    func previous() {
        guard let s = session else { return }
        if s.position > 0 {
            store.setPosition(s.position - 1, for: sessionID)
            loadCurrent()
        } else {
            seek(to: 0)
        }
    }

    func jump(to index: Int) {
        store.setPosition(index, for: sessionID)
        loadCurrent()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func changeRate(by delta: Float) {
        rate = min(max(rate + delta, 0.25), 3.0)
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    /// Shuffles the queue from the current position (current video included)
    /// and switches straight to whichever video lands in the current slot.
    func shuffle() {
        guard let s = session, s.queue.count > 1 else { return }
        store.probabilityShuffle(for: sessionID)
        loadCurrent()
    }
}
