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
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.sessions.isEmpty {
                        Text("No sessions yet. Tap New Session to start.")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(store.sessions) { session in
                        SessionCard(
                            session: session,
                            onView: { path.append(session.id) },
                            onDelete: { pendingDelete = session },
                            onPlay: { coordinator.play(session.id) }
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New Session") {
                        newName = ""
                        showNewAlert = true
                    }
                    .buttonStyle(.bordered)
                }
            }
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
}

struct SessionCard: View {
    let session: Session
    let onView: () -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.name).font(.headline).lineLimit(1)
                Text(session.created.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Queue: \(session.positionLabel)").font(.subheadline)
            }
            Spacer()
            VStack(spacing: 14) {
                Button(action: onView) {
                    Image(systemName: "eye")
                }
                Button(action: onDelete) {
                    Image(systemName: "xmark").foregroundColor(.red)
                }
                Button(action: onPlay) {
                    Image(systemName: "play.square.fill").foregroundColor(.blue)
                }
                .disabled(session.queue.isEmpty)
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.6), lineWidth: 1.5)
        )
    }
}
