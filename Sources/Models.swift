import Foundation

struct QueueItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
}

struct Session: Identifiable, Codable {
    var id = UUID()
    var name: String
    var created = Date()
    var queue: [QueueItem] = []
    var position = 0

    var positionLabel: String {
        queue.isEmpty ? "0 / 0" : "\(position + 1) / \(queue.count)"
    }
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }()

    init() {
        load()
    }

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    @discardableResult
    func createSession(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = Session(name: trimmed.isEmpty ? "Untitled" : trimmed)
        sessions.insert(s, at: 0)
        save()
        return s.id
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func addItems(_ items: [QueueItem], to id: UUID) {
        mutate(id) { $0.queue.append(contentsOf: items) }
    }

    func removeItem(at index: Int, from id: UUID) {
        mutate(id) { s in
            guard s.queue.indices.contains(index) else { return }
            s.queue.remove(at: index)
            if index < s.position { s.position -= 1 }
            s.position = min(s.position, max(s.queue.count - 1, 0))
        }
    }

    func setPosition(_ position: Int, for id: UUID) {
        mutate(id) { s in
            guard s.queue.indices.contains(position) else { return }
            s.position = position
        }
    }

    /// Shuffles the queue from the current position onward, including the current video,
    /// and guarantees a different video lands in the current slot. Watched videos stay put.
    func shuffleFromCurrent(for id: UUID) {
        mutate(id) { s in
            guard s.queue.count - s.position > 1 else { return }
            let currentID = s.queue[s.position].id
            var tail = Array(s.queue[s.position...])
            tail.shuffle()
            if tail[0].id == currentID {
                tail.swapAt(0, Int.random(in: 1..<tail.count))
            }
            s.queue.replaceSubrange(s.position..<s.queue.count, with: tail)
        }
    }

    func updateBookmark(_ data: Data, itemID: UUID, in id: UUID) {
        mutate(id) { s in
            if let i = s.queue.firstIndex(where: { $0.id == itemID }) {
                s.queue[i].bookmark = data
            }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Session].self, from: data) else { return }
        sessions = decoded
    }
}
