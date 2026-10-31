import SwiftUI

struct SessionView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let session = store.session(sessionID) {
                content(session)
            } else {
                // Session was deleted: leave this page.
                Color.clear.onAppear { dismiss() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            VideoPicker { urls in
                store.addItems(makeQueueItems(from: urls), to: sessionID)
                showPicker = false
            }
        }
        .alert("Delete session?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteSession(sessionID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(store.session(sessionID)?.name ?? "This session")\u{201D} and its queue will be deleted.")
        }
    }

    private func content(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(session.name)
                    .font(.largeTitle.weight(.regular))
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark").foregroundColor(.red)
                        Text("close").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button("Play") { coordinator.play(session.id) }
                    .disabled(session.queue.isEmpty)
                Button("Add") { showPicker = true }
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
            .buttonStyle(.bordered)

            Text("QUEUE  ( \(session.positionLabel) )")
                .font(.title3)

            if session.queue.isEmpty {
                Text("The queue is empty. Tap Add to pick some videos.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                queueList(session)
            }
        }
        .padding()
    }

    private func queueList(_ session: Session) -> some View {
        List {
            ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Button {
                        store.setPosition(index, for: session.id)
                        coordinator.play(session.id)
                    } label: {
                        Text(item.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.removeItem(at: index, from: session.id)
                    } label: {
                        Image(systemName: "xmark").foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                // Videos before the current position are greyed out but still tappable.
                .opacity(index < session.position ? 0.4 : 1)
                .listRowBackground(index == session.position ? Color.accentColor.opacity(0.15) : nil)
            }
        }
        .listStyle(.plain)
    }
}
