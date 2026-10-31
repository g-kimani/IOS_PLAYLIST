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
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var hideTask: Task<Void, Never>?

    init(sessionID: UUID, store: SessionStore) {
        self.sessionID = sessionID
        _model = StateObject(wrappedValue: PlayerModel(sessionID: sessionID, store: store))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: model.player).ignoresSafeArea()

            // Tap anywhere on the video to show/hide the overlay.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
                    poke()
                }

            if showOverlay { overlay.transition(.opacity) }
            if showQueue { queuePanel.transition(.move(edge: .trailing)) }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.player.pause()
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showOverlay = false } }

            VStack {
                topBar
                Spacer()
                if let err = model.errorText {
                    Text(err)
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                coordinator.active = nil
            } label: {
                Image(systemName: "xmark").font(.title2.bold()).foregroundColor(.red)
            }
            Spacer()
            Text(titleText).font(.headline).lineLimit(1)
            Spacer()
            Image(systemName: "xmark").font(.title2.bold()).opacity(0) // balances the close button
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(format(scrubbing ? scrubValue : model.currentTime))
                    .font(.caption).monospacedDigit()
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
                Text(format(model.duration))
                    .font(.caption).monospacedDigit()
            }

            HStack(spacing: 24) {
                Button { model.togglePlay(); poke() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                Button { model.previous(); poke() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                Button { model.next(); poke() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                Spacer()
                Text(String(format: "%.1fx", model.rate))
                    .font(.caption).monospacedDigit()
                labeled("tortoise.fill", "SLOW") { model.changeRate(by: -0.5) }
                labeled("hare.fill", "FAST") { model.changeRate(by: 0.5) }
                labeled("shuffle", "SHUFFLE") { model.shuffle() }
                labeled("list.bullet", "QUEUE") {
                    withAnimation { showQueue = true }
                }
            }
        }
        .foregroundColor(.white)
    }

    private func labeled(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            poke()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.system(size: 10))
            }
        }
    }

    // MARK: - Queue panel

    private var queuePanel: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showQueue = false }
                    poke()
                }

            VStack(alignment: .leading, spacing: 0) {
                if let session = store.session(sessionID) {
                    Text("Queue ( \(session.positionLabel) )")
                        .font(.headline)
                        .padding()
                    queueList(session)
                }
            }
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.88).ignoresSafeArea())
        }
    }

    private func queueList(_ session: Session) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, item in
                    Button {
                        model.jump(to: index)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                            Text(item.name)
                                .lineLimit(2)
                                .foregroundColor(index == session.position ? .accentColor : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(index < session.position ? 0.4 : 1)
                    .id(item.id)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if session.queue.indices.contains(session.position) {
                    proxy.scrollTo(session.queue[session.position].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Helpers

    private var titleText: String {
        guard let s = store.session(sessionID), s.queue.indices.contains(s.position) else { return "" }
        return "\(s.position + 1): \(s.queue[s.position].name)"
    }

    /// Auto-hides the overlay a few seconds after the last interaction.
    private func poke() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !showQueue && !scrubbing {
                withAnimation { showOverlay = false }
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
