import Foundation

struct QueueItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
    // Added later; all optional so sessions saved by older builds still load.
    var folder: String? = nil        // first-level subfolder under the library folder
    var rootID: UUID? = nil          // which library folder this video was found in
    var relativePath: String? = nil  // path inside that library folder
}

struct LibraryRoot: Identifiable, Codable {
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

struct RelinkSummary {
    var matched = 0
    var unmatched = 0
    var duplicateNames = 0
    var folders = Set<String>()

    var message: String {
        var parts = ["Relinked \(matched) of \(matched + unmatched) videos."]
        if unmatched > 0 {
            parts.append("\(unmatched) weren't found in that folder and were left in the queue exactly as they were.")
        }
        if duplicateNames > 0 {
            parts.append("\(duplicateNames) share a filename with another file, so the first match was used.")
        }
        if !folders.isEmpty {
            parts.append("Subfolders found: \(folders.count).")
        }
        return parts.joined(separator: " ")
    }
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var roots: [LibraryRoot] = []
    @Published var loadNotice: String?

    private let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var fileURL: URL { documents.appendingPathComponent("sessions.json") }
    private var rootsURL: URL { documents.appendingPathComponent("roots.json") }
    private var backupDir: URL { documents.appendingPathComponent("Backups", isDirectory: true) }

    init() {
        load()
    }

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    func root(_ id: UUID) -> LibraryRoot? {
        roots.first { $0.id == id }
    }

    func clearNotice() {
        loadNotice = nil
    }

    // MARK: - Sessions

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

    // MARK: - Library folders & relinking

    /// Registers a library folder (or finds the existing entry for the same folder).
    func registerRoot(name: String, bookmark: Data) -> UUID {
        if let newPath = resolvedPath(bookmark),
           let i = roots.firstIndex(where: { resolvedPath($0.bookmark) == newPath }) {
            roots[i].bookmark = bookmark
            saveRoots()
            return roots[i].id
        }
        let root = LibraryRoot(name: name, bookmark: bookmark)
        roots.append(root)
        saveRoots()
        return root.id
    }

    /// Re-points queue items at files found in a library folder, matching by filename.
    /// Order and position are untouched. Unmatched items are left exactly as they were.
    func relink(sessionID: UUID, rootID: UUID, files: [String: [ScannedFile]]) -> RelinkSummary {
        save() // make sure the file on disk matches memory, then keep a permanent copy
        if let data = try? Data(contentsOf: fileURL) {
            writeBackup(data, prefix: "keep-before-relink", rotate: false)
        }

        var summary = RelinkSummary()
        mutate(sessionID) { s in
            for i in s.queue.indices {
                guard let candidates = files[s.queue[i].name], let match = candidates.first else {
                    summary.unmatched += 1
                    continue
                }
                s.queue[i].bookmark = match.bookmark
                s.queue[i].folder = match.folder
                s.queue[i].rootID = rootID
                s.queue[i].relativePath = match.relativePath
                summary.matched += 1
                if candidates.count > 1 { summary.duplicateNames += 1 }
                if let f = match.folder { summary.folders.insert(f) }
            }
        }
        return summary
    }

    private func resolvedPath(_ bookmark: Data) -> String? {
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.standardizedFileURL.path
    }

    // MARK: - Persistence

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

    private func saveRoots() {
        do {
            let data = try JSONEncoder().encode(roots)
            try data.write(to: rootsURL, options: .atomic)
        } catch {
            print("Saving library folders failed: \(error)")
        }
    }

    private func load() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: fileURL) {
            // Keep a copy before anything else happens (skipped if identical to the latest one).
            writeBackup(data, prefix: "sessions", rotate: true)
            do {
                sessions = try JSONDecoder().decode([Session].self, from: data)
            } catch {
                // Never overwrite a file we couldn't read: set it aside and tell the user.
                let aside = documents.appendingPathComponent("sessions-unreadable-\(SessionStore.stamp()).json")
                try? fm.moveItem(at: fileURL, to: aside)
                loadNotice = "Your saved sessions couldn't be read, so the file was set aside as \(aside.lastPathComponent) in the app's folder in Files. Nothing was deleted."
            }
        }
        if let data = try? Data(contentsOf: rootsURL),
           let decoded = try? JSONDecoder().decode([LibraryRoot].self, from: data) {
            roots = decoded
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// "sessions-…" backups rotate (latest 15 kept); other prefixes are kept forever.
    private func writeBackup(_ data: Data, prefix: String, rotate: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let existing = ((try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("sessions-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if rotate, let last = existing.last, let lastData = try? Data(contentsOf: last), lastData == data {
            return
        }

        let url = backupDir.appendingPathComponent("\(prefix)-\(SessionStore.stamp()).json")
        try? data.write(to: url, options: .atomic)

        if rotate {
            for old in existing.prefix(max(0, existing.count - 14)) {
                try? fm.removeItem(at: old)
            }
        }
    }
}
