import SwiftUI

struct SessionView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            AppBackground()
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text(session.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                IconButton(systemName: "xmark", size: 40) { dismiss() }
            }

            HStack(spacing: 12) {
                Button {
                    coordinator.play(session.id)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(Theme.gradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(session.queue.isEmpty)
                .opacity(session.queue.isEmpty ? 0.4 : 1)

                IconButton(systemName: "plus", size: 50) { showPicker = true }
                IconButton(systemName: "trash", size: 50, tint: Theme.danger) { confirmDelete = true }
            }

            HStack {
                Text("QUEUE")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Badge(text: session.positionLabel)
            }

            if session.queue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.gradient)
                    Text("Your queue is empty")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                Spacer()
            } else {
                queueList(session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func queueList(_ session: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, item in
                        QueueRow(
                            index: index,
                            item: item,
                            isCurrent: index == session.position,
                            isPast: index < session.position,
                            showDelete: true,
                            onTap: {
                                store.setPosition(index, for: session.id)
                                coordinator.play(session.id)
                            },
                            onDelete: {
                                store.removeItem(at: index, from: session.id)
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.bottom, 24)
            }
            .onAppear {
                if session.queue.indices.contains(session.position) {
                    proxy.scrollTo(session.queue[session.position].id, anchor: .center)
                }
            }
        }
    }
}
