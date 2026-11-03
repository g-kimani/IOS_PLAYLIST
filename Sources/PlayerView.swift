import AVFoundation
import SwiftUI

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @StateObject private var model: PlayerModel

    @State private var showOverlay = false
    @State private var showQueue = false
    @State private var showFavorites = false
    @State private var confirmDiskDelete = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showCountdown = true
    @State private var hideTask: Task<Void, Never>?

    init(sessionID: UUID, store: SessionStore) {
        self.sessionID = sessionID
        _model = StateObject(wrappedValue: PlayerModel(sessionID: sessionID, store: store))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: model.player).ignoresSafeArea()

            // Three gesture zones remain aligned with the screen after rotation.
            GeometryReader { zones in
                HStack(spacing: 0) {
                    Color.clear.frame(width: zones.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) { toggleOverlay() }
                        .onTapGesture(count: 2) { model.seek(to: max(model.currentTime - 5, 0)); poke() }
                        .gesture(DragGesture(minimumDistance: 18).onChanged { value in
                            UIScreen.main.brightness = min(max(UIScreen.main.brightness - value.translation.height / 700, 0), 1)
                        })
                    Color.clear.frame(width: zones.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) { toggleOverlay() }
                        .onTapGesture(count: 2) { model.togglePlay(); poke() }
                    Color.clear.frame(width: zones.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) { toggleOverlay() }
                        .onTapGesture(count: 2) { model.seek(to: min(model.currentTime + 5, model.duration)); poke() }
                }
                .ignoresSafeArea()
            }
            .allowsHitTesting(!showOverlay && !showQueue && !showFavorites)

            // GeometryReader tells us whether we're in portrait or landscape,
            // so the layout re-flows when the phone rotates.
            GeometryReader { geo in
                let portrait = geo.size.height > geo.size.width
                ZStack {
                    if showOverlay {
                        overlay(portrait: portrait).transition(.opacity)
                    }
                    if showQueue {
                        queuePanel(portrait: portrait, size: geo.size).transition(.opacity)
                    }
                    if showFavorites {
                        favoritesPanel(portrait: portrait, size: geo.size).transition(.move(edge: .trailing))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .alert("Delete video from disk?", isPresented: $confirmDiskDelete) {
            Button("Delete", role: .destructive) { deleteCurrentVideo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the video file, not just the queue entry.")
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.player.pause()
        }
    }

    // MARK: - Overlay

    private func overlay(portrait: Bool) -> some View {
        ZStack {
            // Tapping empty space hides the controls again.
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { hideOverlay() }

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
                Spacer()
                if let err = model.errorText {
                    Text(err)
                        .font(.callout)
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.65)))
                        .padding(.horizontal, 24)
                }
                Spacer()
                bottomBar(portrait: portrait)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func topBar(portrait: Bool) -> some View {
        HStack(spacing: 12) {
            IconButton(systemName: "xmark", size: 44, tint: Theme.danger) {
                coordinator.active = nil
            }
            Text(titleText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(portrait ? 2 : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                IconButton(systemName: "doc.on.doc", size: 40) {
                    UIPasteboard.general.string = store.session(sessionID)?.queue.indices.contains(store.session(sessionID)?.position ?? -1) == true
                        ? store.session(sessionID)?.queue[store.session(sessionID)!.position].name : titleText
                    poke()
                }
                IconButton(systemName: "folder.badge.star", size: 40) {
                    showFavorites.toggle()
                    poke()
                }
            }
        }
    }

    private func bottomBar(portrait: Bool) -> some View {
        VStack(spacing: portrait ? 16 : 8) {
            scrubber

            if portrait {
                // Portrait: transport controls centred on one row,
                // speed / shuffle / queue on the row below.
                HStack(spacing: 36) {
                    IconButton(systemName: "backward.fill", size: 50) { model.previous(); poke() }
                    playPauseButton(size: 66)
                    IconButton(systemName: "forward.fill", size: 50) { model.next(); poke() }
                }
                HStack {
                    IconButton(systemName: "tortoise.fill") { model.changeRate(by: -0.25); poke() }
                    Spacer()
                    rateBadge
                    Spacer()
                    IconButton(systemName: "hare.fill") { model.changeRate(by: 0.25); poke() }
                    Spacer()
                    IconButton(systemName: "shuffle") { model.shuffle(); poke() }
                    Spacer()
                    IconButton(systemName: "list.bullet") { openQueue() }
                    IconButton(systemName: "trash", tint: Theme.danger) { confirmDiskDelete = true }
                }
            } else {
                // Landscape: everything on a single row.
                HStack(spacing: 12) {
                    playPauseButton(size: 52)
                    IconButton(systemName: "backward.fill") { model.previous(); poke() }
                    IconButton(systemName: "forward.fill") { model.next(); poke() }
                    Spacer()
                    rateBadge
                    IconButton(systemName: "tortoise.fill") { model.changeRate(by: -0.25); poke() }
                    IconButton(systemName: "hare.fill") { model.changeRate(by: 0.25); poke() }
                    IconButton(systemName: "shuffle") { model.shuffle(); poke() }
                    IconButton(systemName: "list.bullet") { openQueue() }
                    IconButton(systemName: "trash", tint: Theme.danger) { confirmDiskDelete = true }
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

    private var rateBadge: some View {
        Button {
            model.rate = 1.0
            model.player.defaultRate = 1.0
            if model.player.timeControlStatus != .paused { model.player.rate = 1.0 }
            poke()
        } label: {
            Text(String(format: "%.2fx", model.rate))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundColor(.white)
                .frame(minWidth: 44)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(format(scrubbing ? scrubValue : model.currentTime))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 44, alignment: .leading)
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : model.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    if editing { scrubValue = model.currentTime }
                    scrubbing = editing
                    if !editing { model.seek(to: scrubValue) }
                    poke()
                }
            )
            .tint(Theme.accent)
            Button {
                showCountdown.toggle()
                poke()
            } label: {
                Text(format(showCountdown ? max(model.duration - (scrubbing ? scrubValue : model.currentTime), 0) : model.duration))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
    }

    // MARK: - Favourite folders sidebar

    private func favoritesPanel(portrait: Bool, size: CGSize) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { showFavorites = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Favourite folders").font(.headline).foregroundColor(.white)
                    Spacer()
                    IconButton(systemName: "xmark", size: 34) { showFavorites = false }
                }
                Text("Weights influence which folder's videos appear earlier when you shuffle.")
                    .font(.caption).foregroundColor(.white.opacity(0.6))
                if store.roots.isEmpty {
                    Text("Add a library folder to a session first.")
                        .font(.subheadline).foregroundColor(.white.opacity(0.65))
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(store.roots) { root in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(root.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%.1f", root.weight)).font(.caption.monospacedDigit())
                                    }.foregroundColor(.white)
                                    Slider(value: Binding(
                                        get: { root.weight },
                                        set: { store.setRootWeight($0, for: root.id) }
                                    ), in: 0...20, step: 0.5).tint(Theme.accent)
                                }
                                .padding(12).cardStyle(cornerRadius: 14)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: portrait ? min(size.width * 0.88, 380) : min(360, size.width * 0.42), height: size.height)
            .background(panelBackground.ignoresSafeArea())
        }
    }

    // MARK: - Queue panel (side panel in landscape, bottom sheet in portrait)

    private func queuePanel(portrait: Bool, size: CGSize) -> some View {
        ZStack(alignment: portrait ? .bottom : .trailing) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closeQueue() }

            if let session = store.session(sessionID) {
                if portrait {
                    queueContent(session)
                        .frame(maxWidth: .infinity)
                        .frame(height: size.height * 0.58)
                        .background(panelBackground.ignoresSafeArea(edges: .bottom))
                } else {
                    queueContent(session)
                        .frame(width: min(360, size.width * 0.5))
                        .frame(maxHeight: .infinity)
                        .background(panelBackground.ignoresSafeArea())
                }
            }
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(red: 0.08, green: 0.07, blue: 0.14).opacity(0.96))
    }

    private func queueContent(_ session: Session) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Queue")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Badge(text: session.positionLabel)
                Spacer()
                IconButton(systemName: "xmark", size: 34) { closeQueue() }
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

    private func deleteCurrentVideo() {
        guard let session = store.session(sessionID), session.queue.indices.contains(session.position) else { return }
        let index = session.position
        let item = session.queue[index]
        guard let resolved = FileResolver.resolve(item, store: store) else {
            model.errorText = "Couldn't locate the video file to delete."
            return
        }
        do {
            try FileManager.default.removeItem(at: resolved.url)
            resolved.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            store.removeItem(at: index, from: sessionID)
            model.loadCurrent()
        } catch {
            resolved.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            model.errorText = "Delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private var titleText: String {
        guard let s = store.session(sessionID), s.queue.indices.contains(s.position) else { return "" }
        return "\(s.position + 1): \(s.queue[s.position].name)"
    }

    private func toggleOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        if showOverlay { poke() }
    }

    private func hideOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
    }

    private func openQueue() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showQueue = true }
    }

    private func closeQueue() {
        withAnimation(.easeInOut(duration: 0.2)) { showQueue = false }
        poke()
    }

    /// Auto-hides the controls a few seconds after the last interaction.
    private func poke() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !showQueue && !scrubbing {
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
