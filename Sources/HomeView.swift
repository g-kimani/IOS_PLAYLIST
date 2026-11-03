import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    @State private var path: [UUID] = []
    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var pendingDelete: Session?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if let notice = store.loadNotice { noticeBanner(notice) }
                        if store.sessions.isEmpty { emptyState }
                        ForEach(store.sessions) { session in
                            SessionCard(
                                session: session,
                                onView: { path.append(session.id) },
                                onDelete: { pendingDelete = session },
                                onPlay: { coordinator.play(session.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                SessionView(sessionID: id)
            }
            .alert("New Session", isPresented: $showNewAlert) {
                TextField("Session name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let id = store.createSession(name: newName)
                    path.append(id)
                }
            }
            .alert(
                "Delete session?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { session in
                Button("Delete", role: .destructive) { store.deleteSession(session.id) }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("\u{201C}\(session.name)\u{201D} and its queue will be deleted.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text(store.sessions.count == 1 ? "1 session" : "\(store.sessions.count) sessions")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            Button {
                newName = ""
                showNewAlert = true
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.gradient))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.top, 12)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", size: 30) { store.clearNotice() }
        }
        .padding(12)
        .cardStyle(cornerRadius: 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.gradient)
            Text("No sessions yet")
                .font(.headline)
            Text("Create a session, add some videos and pick up where you left off.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct SessionCard: View {
    let session: Session
    let onView: () -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void

    private var fraction: Double {
        session.queue.isEmpty ? 0 : Double(session.position + 1) / Double(session.queue.count)
    }

    private var cover: some View {
        // Stable per-session colour derived from the session id.
        let h = Double(session.id.uuid.0) / 255.0
        let h2 = (h + 0.12).truncatingRemainder(dividingBy: 1)
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hue: h, saturation: 0.55, brightness: 0.85),
                             Color(hue: h2, saturation: 0.65, brightness: 0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(width: 52, height: 52)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(session.created.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Theme.gradient)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)

            HStack(spacing: 10) {
                Text("Queue: \(session.positionLabel)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                IconButton(systemName: "eye", size: 40, action: onView)
                IconButton(systemName: "xmark", size: 40, tint: Theme.danger, action: onDelete)
                IconButton(systemName: "play.fill", size: 40, filled: true, action: onPlay)
                    .opacity(session.queue.isEmpty ? 0.4 : 1)
                    .disabled(session.queue.isEmpty)
            }
        }
        .padding(16)
        .cardStyle(cornerRadius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onView)
    }
}
