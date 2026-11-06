import AVFoundation
import SwiftUI

struct PlayerLayerView: UIViewRepresentable {
    let model: PlayerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = model.videoView
        view.alpha = 1
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        coordinator.model.parkVideoViewIfNeeded()
    }

    final class Coordinator {
        let model: PlayerModel
        init(model: PlayerModel) { self.model = model }
    }
}

/// Phone battery for the overlay.
final class BatteryMonitor: ObservableObject {
    @Published var percent: Int = -1
    @Published var charging = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let nc = NotificationCenter.default
        tokens = [
            nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            },
            nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        ]
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func refresh() {
        let level = UIDevice.current.batteryLevel
        percent = level < 0 ? -1 : Int((level * 100).rounded())
        let state = UIDevice.current.batteryState
        charging = (state == .charging || state == .full)
    }
}

enum TouchRegion {
    case left, center, right
}

enum PanelKind {
    case queue, folders
}

enum FolderTab {
    case weights, progress
}

enum HUDKind: Equatable {
    case brightness, volume, play, pause
    case seekBack(Int), seekForward(Int)
    case message(String)
}

struct HUD: Equatable {
    var kind: HUDKind
    var value: Double = 0
}

struct PanelFrame: ViewModifier {
    let portrait: Bool
    let size: CGSize

    func body(content: Content) -> some View {
        let background = RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(red: 0.08, green: 0.07, blue: 0.14).opacity(0.96))
        if portrait {
            content
                .frame(maxWidth: .infinity)
                .frame(height: size.height * 0.58)
                .background(background.ignoresSafeArea(edges: .bottom))
        } else {
            content
                .frame(width: min(360, size.width * 0.5))
                .frame(maxHeight: .infinity)
                .background(background.ignoresSafeArea())
        }
    }
}

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @StateObject private var battery = BatteryMonitor()

    @State private var showOverlay = false
    @State private var panel: PanelKind?
    @State private var folderTab: FolderTab = .weights
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var wasPlayingBeforeScrub = false
    @AppStorage("showRemainingTime") private var showRemaining = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hud: HUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var dragActive = false
    @State private var dragStart: Double = 0
    @State private var confirmDeleteFile = false
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var panActive = false
    @GestureState private var isPinching = false
    @State private var seekAccum = 0
    @State private var lastSeekDirection = 0
    @State private var lastSeekTime = Date.distantPast

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(model: model)
                .ignoresSafeArea()
                .scaleEffect(zoom)
                .offset(pan)

            // Touch controls: three regions across the full screen.
            GeometryReader { geo in
                touchLayer(size: geo.size)
            }
            .ignoresSafeArea()

            // Controls re-flow when the phone rotates.
            GeometryReader { geo in
                let portrait = geo.size.height > geo.size.width
                ZStack {
                    if showOverlay {
                        overlay(portrait: portrait).transition(.opacity)
                    }
                    if let kind = panel {
                        panelView(kind, portrait: portrait, size: geo.size).transition(.opacity)
                    }
                    hudView().allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            SystemVolume.shared.attach()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            coordinator.coverDismissed()
        }
        .onChange(of: model.loadedItemID) { _ in resetZoom() }
        .onChange(of: model.notice) { message in
            if let message = message {
                showHUD(.message(message))
                model.notice = nil
            }
        }
        .alert("Delete this video?", isPresented: $confirmDeleteFile) {
            Button("Move to Recently Deleted", role: .destructive) { model.deleteCurrentFromDisk() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(currentName)\u{201D} will be moved to Recently Deleted in the Files app, where you can restore it for 30 days.")
        }
    }

    // MARK: - Touch controls

    private func touchLayer(size: CGSize) -> some View {
        HStack(spacing: 0) {
            touchRegion(.left, size: size).frame(width: size.width * 0.32)
            touchRegion(.center, size: size).frame(width: size.width * 0.36)
            touchRegion(.right, size: size).frame(width: size.width * 0.32)
        }
        // Pinch anywhere on the video to zoom; one finger pans while zoomed in.
        .simultaneousGesture(
            MagnificationGesture()
                .updating($isPinching) { _, state, _ in state = true }
                .onChanged { value in
                    zoom = min(max(zoomBase * value, 1), 5)
                    pan = clampedPan(pan, size: size)
                    showHUD(.message(String(format: "Zoom %.1fx", Double(zoom))))
                }
                .onEnded { _ in
                    if zoom < 1.05 {
                        resetZoom()
                    } else {
                        zoomBase = zoom
                        pan = clampedPan(pan, size: size)
                        panBase = pan
                    }
                }
        )
    }

    private func touchRegion(_ region: TouchRegion, size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTap(region) }
            .onTapGesture { toggleOverlay() }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        drag(region, translation: value.translation, size: size)
                    }
                    .onEnded { value in
                        finishDrag(value)
                    }
            )
    }

    private func doubleTap(_ region: TouchRegion) {
        switch region {
        case .left, .right:
            // Quick repeated double taps in the same direction add up: 5s, 10s, 15s...
            let direction = region == .left ? -1 : 1
            let now = Date()
            if direction == lastSeekDirection && now.timeIntervalSince(lastSeekTime) < 0.85 {
                seekAccum += 5
            } else {
                seekAccum = 5
            }
            lastSeekDirection = direction
            lastSeekTime = now
            model.seek(by: Double(direction * 5))
            showHUD(direction < 0 ? .seekBack(seekAccum) : .seekForward(seekAccum))
        case .center:
            let willPlay = !model.isPlaying
            model.togglePlay()
            showHUD(willPlay ? .play : .pause)
        }
    }

    /// When a drag ends: a quick swipe down while zoomed in snaps the zoom back to normal.
    private func finishDrag(_ value: DragGesture.Value) {
        defer {
            dragActive = false
            panActive = false
        }
        guard zoom > 1.01 else { return }
        let dx = value.translation.width
        let dy = value.translation.height
        let momentum = value.predictedEndTranslation.height - dy   // how much further a flick would carry
        if dy > 60 && abs(dy) > abs(dx) * 1.5 && momentum > 120 {
            resetZoom()
        }
    }

    /// Vertical swipe: left side = screen brightness, right side = volume.
    /// A swipe over ~80% of the screen height covers the full range, so movement is very fine-grained.
    /// While zoomed in, one finger pans the picture instead.
    private func drag(_ region: TouchRegion, translation: CGSize, size: CGSize) {
        // Zoomed in: one finger pans the picture (this also works straight after a pinch).
        if zoom > 1.01 {
            if !panActive {
                panActive = true
                panBase = pan
            }
            pan = clampedPan(
                CGSize(width: panBase.width + translation.width, height: panBase.height + translation.height),
                size: size
            )
            return
        }

        guard !isPinching, region != .center else { return }
        if !dragActive {
            guard abs(translation.height) > abs(translation.width) else { return }
            dragActive = true
            dragStart = region == .left ? Double(UIScreen.main.brightness) : Double(SystemVolume.shared.current)
        }
        let delta = -Double(translation.height) / Double(max(size.height * 0.8, 1))
        let value = min(max(dragStart + delta, 0), 1)
        if region == .left {
            UIScreen.main.brightness = CGFloat(value)
            showHUD(.brightness, value: value)
        } else {
            SystemVolume.shared.set(Float(value))
            showHUD(.volume, value: value)
        }
    }

    // MARK: - HUD

    private func showHUD(_ kind: HUDKind, value: Double = 0) {
        hud = HUD(kind: kind, value: value)
        hudTask?.cancel()
        hudTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { hud = nil }
            }
        }
    }

    @ViewBuilder
    private func hudView() -> some View {
        if let hud = hud {
            switch hud.kind {
            case .brightness:
                levelHUD(icon: "sun.max.fill", value: hud.value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 84)
            case .volume:
                levelHUD(icon: volumeIcon(hud.value), value: hud.value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 24)
            case .seekBack(let seconds):
                flashHUD(icon: "gobackward", text: "-\(seconds)s")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 100)
            case .seekForward(let seconds):
                flashHUD(icon: "goforward", text: "+\(seconds)s")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 56)
            case .play:
                flashHUD(icon: "play.fill", text: nil)
            case .pause:
                flashHUD(icon: "pause.fill", text: nil)
            case .message(let text):
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
            }
        }
    }

    private func levelHUD(icon: String, value: Double) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.gradient)
                    .frame(height: max(6, 120 * CGFloat(value)))
            }
            .frame(width: 6, height: 120)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func flashHUD(icon: String, text: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold))
            if let text = text {
                Text(text).font(.caption.weight(.bold))
            }
        }
        .foregroundColor(.white)
        .frame(width: 84, height: 84)
        .background(Circle().fill(Color.black.opacity(0.55)))
    }

    private func volumeIcon(_ value: Double) -> String {
        if value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.34 { return "speaker.wave.1.fill" }
        if value < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Overlay

    private func overlay(portrait: Bool) -> some View {
        ZStack {
            // Dimming only; touches pass through to the touch controls underneath.
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.75), Color.clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: portrait ? 300 : 190)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar(portrait: portrait)
                ZStack {
                    if let err = model.errorText {
                        Text(err)
                            .font(.callout)
                            .foregroundColor(.yellow)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.65)))
                            .padding(.horizontal, 64)
                    }
                    HStack {
                        sideButtons
                        Spacer()
                    }
                }
                .frame(maxHeight: .infinity)
                bottomBar(portrait: portrait)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func topBar(portrait: Bool) -> some View {
        let sideWidth: CGFloat = portrait ? 90 : 150
        return HStack(spacing: 8) {
            statusInfo(portrait: portrait)
                .frame(width: sideWidth, alignment: .leading)

            Text(titleText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(portrait ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            IconButton(systemName: "xmark", size: 44, tint: Theme.danger) {
                coordinator.close()
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
    }

    /// Phone clock and battery, so you don't have to leave the video to check them.
    private func statusInfo(portrait: Bool) -> some View {
        let clock = TimelineView(.everyMinute) { context in
            Text(context.date, style: .time)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        let batteryView = HStack(spacing: 3) {
            Image(systemName: batteryIcon).font(.system(size: 15))
            Text("\(battery.percent)%").font(.caption.monospacedDigit())
        }
        return Group {
            if portrait {
                VStack(alignment: .leading, spacing: 2) {
                    clock
                    if battery.percent >= 0 { batteryView }
                }
            } else {
                HStack(spacing: 8) {
                    clock
                    if battery.percent >= 0 { batteryView }
                }
            }
        }
        .foregroundColor(.white)
    }

    private var batteryIcon: String {
        if battery.charging { return "battery.100.bolt" }
        switch battery.percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var sideButtons: some View {
        VStack(spacing: 8) {
            IconButton(systemName: "trash", size: 40, tint: Theme.danger) {
                confirmDeleteFile = true
                poke()
            }
            IconButton(systemName: model.isPiPActive ? "pip.exit" : "pip.enter", size: 40) {
                model.togglePiP()
                poke()
            }
            IconButton(systemName: "doc.on.doc", size: 40) {
                UIPasteboard.general.string = currentName
                showHUD(.message("Title copied"))
                poke()
            }
        }
    }

    private var folderButton: some View {
        CircleButton(size: 44, action: { openPanel(.folders) }) {
            FolderHeartIcon()
        }
    }

    private func bottomBar(portrait: Bool) -> some View {
        VStack(spacing: portrait ? 14 : 6) {
            scrubber

            if portrait {
                // Portrait: previous / play / next centred, everything else on the row below.
                HStack(spacing: 36) {
                    IconButton(systemName: "backward.fill", size: 50) { model.previous(); poke() }
                    playPauseButton(size: 66)
                    IconButton(systemName: "forward.fill", size: 50) { model.next(); poke() }
                }
                HStack {
                    IconButton(systemName: "shuffle") { model.shuffle(); poke() }
                    Spacer()
                    folderButton
                    Spacer()
                    rateButton
                    Spacer()
                    IconButton(systemName: "tortoise.fill") { model.changeRate(by: -0.25); poke() }
                    Spacer()
                    IconButton(systemName: "hare.fill") { model.changeRate(by: 0.25); poke() }
                    Spacer()
                    IconButton(systemName: "list.bullet") { openPanel(.queue) }
                }
            } else {
                // Landscape: play / pause in the middle with four buttons either side.
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        IconButton(systemName: "shuffle") { model.shuffle(); poke() }
                        IconButton(systemName: "backward.fill") { model.previous(); poke() }
                        IconButton(systemName: "forward.fill") { model.next(); poke() }
                        folderButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    playPauseButton(size: 56)

                    HStack(spacing: 10) {
                        rateButton
                        IconButton(systemName: "tortoise.fill") { model.changeRate(by: -0.25); poke() }
                        IconButton(systemName: "hare.fill") { model.changeRate(by: 0.25); poke() }
                        IconButton(systemName: "list.bullet") { openPanel(.queue) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func playPauseButton(size: CGFloat) -> some View {
        IconButton(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: size, filled: true) {
            model.togglePlay()
            poke()
        }
    }

    /// Shows the current speed. Tap resets this video to 1x; hold to lock or unlock the speed
    /// so it carries over to other videos (videos under a minute still play at 1x).
    private var rateButton: some View {
        let locked = model.lockedRate != nil
        return HStack(spacing: 4) {
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
            }
            Text(rateText).font(.caption.monospacedDigit().weight(.bold))
        }
        .foregroundColor(.white)
        .frame(minWidth: 48, minHeight: 36)
        .padding(.horizontal, 6)
        .background(Capsule().fill(locked ? Theme.accent.opacity(0.6) : Color.white.opacity(0.14)))
        .contentShape(Capsule())
        .onTapGesture {
            model.resetRate()
            showHUD(.message("Speed reset to 1x"))
            poke()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            let nowLocked = model.toggleRateLock()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if nowLocked, let r = model.lockedRate {
                showHUD(.message("Speed locked at \(speedString(r))"))
            } else {
                showHUD(.message("Speed unlocked"))
            }
            poke()
        }
    }

    private var rateText: String {
        speedString(model.rate)
    }

    private func speedString(_ rate: Float) -> String {
        let r = Double(rate)
        let text = r == r.rounded() ? String(format: "%.1f", r) : String(format: "%g", r)
        return text + "x"
    }

    private var scrubber: some View {
        let displayed = scrubbing ? scrubValue : model.currentTime
        return HStack(spacing: 10) {
            Text(format(displayed))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 48, alignment: .leading)

            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : model.currentTime },
                    set: { newValue in
                        scrubValue = newValue
                        if scrubbing { model.scrub(to: newValue) }   // the frame follows the thumb while dragging
                    }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = model.currentTime
                        wasPlayingBeforeScrub = model.isPlaying
                        scrubbing = true
                        model.beginScrub()
                    } else {
                        scrubbing = false
                        model.endScrub(at: scrubValue, resume: wasPlayingBeforeScrub)
                    }
                    poke()
                }
            )
            .tint(Theme.accent)

            remainingLabel(displayed: displayed)
        }
        .foregroundColor(.white)
    }

    /// Time left (tap for total length) and, when the speed isn't 1x, the same time at the current speed.
    private func remainingLabel(displayed: Double) -> some View {
        let value = showRemaining ? max(model.duration - displayed, 0) : model.duration
        let speed = Double(model.rate)
        let sign = showRemaining ? "-" : ""
        return Button {
            showRemaining.toggle()
            poke()
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text(sign + format(value))
                    .font(.caption.monospacedDigit())
                if abs(speed - 1.0) > 0.001 {
                    Text(sign + format(value / speed))
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundColor(Theme.accent2)
                }
            }
            .foregroundColor(.white)
            .frame(minWidth: 56, minHeight: 36, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Side panels (queue / favourite folders)

    @ViewBuilder
    private func panelView(_ kind: PanelKind, portrait: Bool, size: CGSize) -> some View {
        ZStack(alignment: portrait ? .bottom : .leading) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }

            if let session = store.session(model.sessionID) {
                Group {
                    switch kind {
                    case .queue: queueContent(session)
                    case .folders: folderContent(session)
                    }
                }
                .modifier(PanelFrame(portrait: portrait, size: size))
            }
        }
    }

    private func queueContent(_ session: Session) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Queue")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Badge(text: session.positionLabel)
                Spacer()
                IconButton(systemName: "xmark", size: 34) { closePanel() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, item in
                            QueueRow(
                                index: index,
                                item: item,
                                isCurrent: index == session.position,
                                isPast: index < session.position,
                                onTap: { model.jump(to: index) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .onAppear {
                    if session.queue.indices.contains(session.position) {
                        proxy.scrollTo(session.queue[session.position].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func folderContent(_ session: Session) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Favourite folders")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                if folderTab == .weights {
                    // Sets every folder back to weight 1.
                    IconButton(systemName: "arrow.counterclockwise", size: 34) {
                        store.resetWeights(for: model.sessionID)
                    }
                }
                IconButton(systemName: "xmark", size: 34) { closePanel() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Picker("View", selection: $folderTab) {
                Text("Weights").tag(FolderTab.weights)
                Text("Progress").tag(FolderTab.progress)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            switch folderTab {
            case .weights:
                weightsList(session)
            case .progress:
                progressList(session)
            }
        }
    }

    @ViewBuilder
    private func weightsList(_ session: Session) -> some View {
        let folders = session.folderSummaries
        if folders.isEmpty {
            noFoldersMessage
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(folders) { folder in
                        folderRow(folder, in: session)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var noFoldersMessage: some View {
        Text("None of the videos in this queue are in a subfolder yet. Use Add folder or Relink on the session page to pick up subfolders.")
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(24)
    }

    @ViewBuilder
    private func progressList(_ session: Session) -> some View {
        let rows = session.folderProgress
        ScrollView {
            LazyVStack(spacing: 8) {
                progressCard(
                    title: "Whole queue",
                    watched: min(session.position, session.queue.count),
                    remaining: max(session.queue.count - session.position, 0)
                )
                ForEach(rows) { row in
                    progressCard(title: row.name, watched: row.watched, remaining: row.remaining)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private func progressCard(title: String, watched: Int, remaining: Int) -> some View {
        let total = watched + remaining
        let fraction = total == 0 ? 0 : CGFloat(watched) / CGFloat(total)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Badge(text: "\(watched) / \(total)")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Theme.gradient)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            HStack(spacing: 14) {
                Label("\(watched) watched", systemImage: "checkmark.circle.fill")
                Label("\(remaining) left", systemImage: "hourglass")
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(12)
        .cardStyle(cornerRadius: 14)
    }

    private func folderRow(_ folder: FolderSummary, in session: Session) -> some View {
        let remaining = session.folderProgress.first(where: { $0.name == folder.name })?.remaining ?? 0
        return FolderWeightRow(
            name: folder.name,
            total: folder.count,
            remaining: remaining,
            weight: session.weight(for: folder.name)
        ) { newValue in
            store.setWeight(newValue, folder: folder.name, for: model.sessionID)
        }
    }

    // MARK: - Helpers

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            zoomBase = 1
            pan = .zero
            panBase = .zero
        }
    }

    /// Keeps the zoomed picture from being dragged completely out of view.
    private func clampedPan(_ value: CGSize, size: CGSize) -> CGSize {
        let maxX = size.width * (zoom - 1) / 2
        let maxY = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    private var currentName: String {
        guard let s = store.session(model.sessionID), s.queue.indices.contains(s.position) else { return "" }
        return s.queue[s.position].name
    }

    private var titleText: String {
        guard let s = store.session(model.sessionID), s.queue.indices.contains(s.position) else { return "" }
        return "\(s.position + 1): \(s.queue[s.position].name)"
    }

    private func toggleOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        if showOverlay { poke() }
    }

    private func openPanel(_ kind: PanelKind) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { panel = kind }
    }

    private func closePanel() {
        withAnimation(.easeInOut(duration: 0.2)) { panel = nil }
        poke()
    }

    /// Auto-hides the controls a few seconds after the last interaction.
    private func poke() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && panel == nil && !scrubbing {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
            }
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}


/// One favourite-folder row. The slider keeps its value locally while you drag and only saves when you
/// let go, and it takes hold of the touch immediately so the scroll view behind it can't make it feel sticky.
struct FolderWeightRow: View {
    let name: String
    let total: Int
    let remaining: Int
    let weight: Int
    let onCommit: (Int) -> Void

    @State private var value: Int
    @State private var dragging = false

    init(name: String, total: Int, remaining: Int, weight: Int, onCommit: @escaping (Int) -> Void) {
        self.name = name
        self.total = total
        self.remaining = remaining
        self.weight = weight
        self.onCommit = onCommit
        _value = State(initialValue: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Badge(text: "\(value)")
            }
            Text("\(remaining) left of \(total)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
            slider
        }
        .padding(12)
        .cardStyle(cornerRadius: 14)
        .onChange(of: weight) { newValue in
            if !dragging { value = newValue }
        }
    }

    private var slider: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 26
            let travel = max(geo.size.width - thumb, 1)
            let fraction = CGFloat(value - 1) / 19
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 6)
                Capsule().fill(Theme.gradient)
                    .frame(width: thumb / 2 + travel * fraction, height: 6)
                Circle().fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: Color.black.opacity(0.3), radius: 2)
                    .offset(x: travel * fraction)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let f = min(max((drag.location.x - thumb / 2) / travel, 0), 1)
                        let newValue = 1 + Int((f * 19).rounded())
                        if newValue != value {
                            value = newValue
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit(value)
                    }
            )
        }
        .frame(height: 32)
    }
}
