import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class PlayerModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let sessionID: UUID
    let store: SessionStore
    let player = AVPlayer()
    let videoView = PlayerUIView()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var rate: Float = 1.0
    @Published var errorText: String?
    @Published var notice: String?
    @Published var isPiPActive = false
    @Published var lockedRate: Float?

    // Hooks the coordinator uses to react to PiP and deletion events.
    var onPiPWillStart: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPStopped: (() -> Void)?
    var onQueueEmptied: (() -> Void)?

    @Published private(set) var loadedItemID: UUID?

    private var pip: AVPictureInPictureController?
    private var pipStarting = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var bgObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?
    private var accessedURLs: [URL] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var isSeeking = false
    private var pendingSeek: Double?
    private var lastNowPlayingSecond = -1
    private var durationCancellable: AnyCancellable?
    private var lastProgressSave: Double = 0
    private var tapSeekTarget: Double?
    private var tapSeekDate = Date.distantPast

    var keepAliveForPiP: Bool { pipStarting || isPiPActive }

    init(sessionID: UUID, store: SessionStore) {
        self.sessionID = sessionID
        self.store = store
        super.init()

        let storedRate = UserDefaults.standard.double(forKey: "lockedRate")
        lockedRate = storedRate > 0 ? Float(storedRate) : nil

        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect

        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            controller?.delegate = self
            pip = controller
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
            if abs(self.currentTime - self.lastProgressSave) >= 5 {
                self.saveProgress()
            }
            let second = Int(self.currentTime)
            if second != self.lastNowPlayingSecond {
                self.lastNowPlayingSecond = second
                self.updateNowPlaying()
            }
        }

        // Keeps the play/pause icon in sync even while paused.
        statusCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status != .paused)
                if status == .paused { self?.saveProgress() }
                self?.updateNowPlaying()
            }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.itemFinished()
        }

        // Background play: with the video layer attached iOS pauses playback when the app is
        // backgrounded, so detach it (audio carries on) unless Picture in Picture is showing it.
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveProgress()
            guard let self = self, !self.keepAliveForPiP else { return }
            self.videoView.playerLayer.player = nil
        }
        fgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.videoView.playerLayer.player = self.player
        }

        setupRemoteCommands()
        loadCurrent()
    }

    deinit {
        tearDown()
    }

    private var session: Session? { store.session(sessionID) }

    // MARK: - Lifecycle

    /// Stops everything. The coordinator calls this when the player is done with.
    func shutdown() {
        saveProgress()
        onPiPWillStart = nil
        onPiPRestore = nil
        onPiPStopped = nil
        onQueueEmptied = nil
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        pip?.delegate = nil
        tearDown()
        pipStarting = false
        isPiPActive = false
    }

    private func tearDown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = []
        if let t = timeObserver {
            player.removeTimeObserver(t)
            timeObserver = nil
        }
        for observer in [endObserver, bgObserver, fgObserver] {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        }
        endObserver = nil
        bgObserver = nil
        fgObserver = nil
        statusCancellable = nil
        durationCancellable = nil
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        videoView.removeFromSuperview()
    }

    /// If the session's current video isn't what's loaded (e.g. the user tapped another one), load it.
    func syncToSession() {
        guard let s = session, s.queue.indices.contains(s.position) else { return }
        if loadedItemID != s.queue[s.position].id { loadCurrent() }
    }

    // MARK: - Loading

    func loadCurrent(autoplay: Bool = true) {
        saveProgress()   // remember where we were in the video we're leaving
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = []
        errorText = nil
        currentTime = 0
        duration = 0
        durationCancellable = nil
        // Speed starts back at 1x for a new video (a locked speed is applied once the length is known).
        rate = 1.0
        player.defaultRate = 1.0

        guard let session = session, session.queue.indices.contains(session.position) else {
            loadedItemID = nil
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = session.queue[session.position]
        loadedItemID = item.id
        lastProgressSave = 0

        guard let resolved = FileResolver.resolve(item, store: store) else {
            player.replaceCurrentItem(with: nil)
            errorText = "Can't open \(item.name). The file may have been moved or deleted."
            return
        }
        accessedURLs = resolved.scopedURLs
        if let fresh = resolved.refreshedBookmark {
            store.updateBookmark(fresh, itemID: item.id, in: sessionID)
        }

        let playerItem = AVPlayerItem(url: resolved.url)
        // Pick up where this video was left off.
        if let saved = store.progress(for: item.id), saved > 3 {
            playerItem.seek(to: CMTime(seconds: saved, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            currentTime = saved
            lastProgressSave = saved
        }
        watchDuration(of: playerItem)
        player.replaceCurrentItem(with: playerItem)
        if autoplay { play() }
        updateNowPlaying()
    }

    private func watchDuration(of item: AVPlayerItem) {
        durationCancellable = item.publisher(for: \.duration)
            .filter { $0.isNumeric && $0.seconds > 0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self = self else { return }
                self.duration = time.seconds
                self.applyLockedRate()
            }
    }

    /// A locked speed carries over to new videos, except short ones (under a minute) which play at 1x.
    private func applyLockedRate() {
        guard let locked = lockedRate, duration >= 60 else { return }
        rate = locked
        player.defaultRate = locked
        if player.timeControlStatus != .paused { player.rate = locked }
    }

    // MARK: - Resume points

    private func saveProgress() {
        guard let id = loadedItemID, duration > 0 else { return }
        let t = currentTime
        if t > 3 && duration - t > 5 {
            store.setProgress(t, for: id)
        } else {
            store.setProgress(nil, for: id)   // at the very start or the very end: nothing to resume
        }
        lastProgressSave = t
    }

    private func itemFinished() {
        if let id = loadedItemID { store.setProgress(nil, for: id) }
        lastProgressSave = 0
        next()
    }

    // MARK: - Transport

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

    /// Within the first 10 seconds this goes to the previous video; later on it restarts the current one.
    func previous() {
        guard let s = session else { return }
        if currentTime <= 10 && s.position > 0 {
            store.setPosition(s.position - 1, for: sessionID)
            loadCurrent()
        } else {
            seek(to: 0)
            if let id = loadedItemID { store.setProgress(nil, for: id) }
            lastProgressSave = 0
        }
    }

    func jump(to index: Int) {
        store.setPosition(index, for: sessionID)
        loadCurrent()
    }

    // MARK: - Seeking

    /// Exact seek (used for double-tap skips and when a scrub ends).
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func seek(by delta: Double) {
        var base = player.currentTime().seconds
        // Quick repeated skips build on the previous target rather than the lagging playhead.
        if let t = tapSeekTarget, Date().timeIntervalSince(tapSeekDate) < 1.0 { base = t }
        guard base.isFinite else { return }
        var target = base + delta
        if duration > 0 { target = min(target, max(duration - 0.1, 0)) }
        target = max(target, 0)
        tapSeekTarget = target
        tapSeekDate = Date()
        seek(to: target)
    }

    func beginScrub() {
        player.pause()
    }

    /// Called continuously while the progress bar is dragged so the frame on screen follows the thumb.
    /// Only one seek is in flight at a time; the latest requested position is chased.
    func scrub(to seconds: Double) {
        currentTime = seconds
        if isSeeking {
            pendingSeek = seconds
            return
        }
        isSeeking = true
        let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSeeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.scrub(to: next)
                }
            }
        }
    }

    func endScrub(at seconds: Double, resume: Bool) {
        pendingSeek = nil
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSeeking = false
                if resume { self.play() }
            }
        }
    }

    // MARK: - Speed

    func changeRate(by delta: Float) {
        rate = min(max(rate + delta, 0.25), 3.0)
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    func resetRate() {
        rate = 1.0
        player.defaultRate = 1.0
        if player.timeControlStatus != .paused { player.rate = 1.0 }
    }

    /// Locks the current speed so it carries over to other videos, or unlocks it. Returns true if now locked.
    func toggleRateLock() -> Bool {
        if lockedRate != nil {
            lockedRate = nil
            UserDefaults.standard.removeObject(forKey: "lockedRate")
            return false
        }
        lockedRate = rate
        UserDefaults.standard.set(Double(rate), forKey: "lockedRate")
        return true
    }

    // MARK: - Shuffle

    /// Weighted shuffle from the current position (current video included), then jump to
    /// whichever video landed in the current slot.
    func shuffle() {
        guard let s = session, s.queue.count - s.position > 1 else { return }
        store.shuffleFromCurrent(for: sessionID)
        loadCurrent()
    }

    // MARK: - Delete from disk

    func deleteCurrentFromDisk() {
        guard let s = session, s.queue.indices.contains(s.position) else { return }
        let item = s.queue[s.position]

        // Let go of the file before deleting it.
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = []
        player.pause()
        player.replaceCurrentItem(with: nil)

        guard let resolved = FileResolver.resolve(item, store: store) else {
            loadCurrent()
            errorText = "Couldn't find \(item.name) to delete."
            return
        }
        defer { resolved.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: resolved.url,
            options: .forDeleting,
            error: &coordinationError
        ) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }
        var failure: Error? = deleteError
        if failure == nil, let ce = coordinationError { failure = ce }
        if let failure = failure {
            loadCurrent()
            errorText = "Couldn't delete \(item.name): \(failure.localizedDescription)"
            return
        }

        store.removeItems(sameFileAs: item, from: sessionID)
        store.setProgress(nil, for: item.id)
        loadedItemID = nil
        notice = "Deleted \(item.name)"
        if let updated = session, !updated.queue.isEmpty {
            loadCurrent()
        } else {
            onQueueEmptied?()
        }
    }

    // MARK: - Picture in Picture

    func togglePiP() {
        guard let pip = pip else {
            notice = "Picture in Picture isn't available here."
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            notice = "Picture in Picture isn't ready yet. Try again in a moment."
        }
    }

    /// When the full-screen player closes while PiP is running, the video layer has to stay
    /// alive in a window, so park it there (2pt, nearly invisible).
    func parkVideoViewIfNeeded() {
        guard keepAliveForPiP else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            guard let host = window else { return }
            self.videoView.removeFromSuperview()
            self.videoView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            self.videoView.alpha = 0.02
            host.addSubview(self.videoView)
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipStarting = true
        isPiPActive = true
        onPiPWillStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipStarting = false
        isPiPActive = false
        onPiPStopped?()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        pipStarting = false
        isPiPActive = false
        notice = "Picture in Picture couldn't start."
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onPiPRestore?()
        completionHandler(true)
    }

    // MARK: - Lock screen / Control Centre

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        func add(_ command: MPRemoteCommand, _ handler: @escaping () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { _ in
                handler()
                return .success
            }
            remoteTargets.append((command, token))
        }

        add(center.playCommand) { [weak self] in self?.play() }
        add(center.pauseCommand) { [weak self] in self?.player.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.togglePlay() }
        add(center.nextTrackCommand) { [weak self] in self?.next() }
        add(center.previousTrackCommand) { [weak self] in self?.previous() }

        center.changePlaybackPositionCommand.isEnabled = true
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, token))
    }

    private func removeRemoteCommands() {
        for (command, token) in remoteTargets {
            command.removeTarget(token)
        }
        remoteTargets = []
    }

    private func updateNowPlaying() {
        guard let s = session, s.queue.indices.contains(s.position) else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.queue[s.position].name,
            MPMediaItemPropertyAlbumTitle: s.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
