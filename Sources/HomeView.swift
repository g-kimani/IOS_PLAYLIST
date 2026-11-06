import SwiftUI

enum ImportSheet: Identifiable {
    case textFile, folder

    var id: String { self == .textFile ? "textFile" : "folder" }
}

struct PendingImport {
    let name: String
    let names: [String]
}

struct HomeView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    @State private var path: [UUID] = []
    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var pendingDelete: Session?
    @State private var importSheet: ImportSheet?
    @State private var pendingImport: PendingImport?
    @State private var showImportPrompt = false
    @State private var isWorking = false
    @State private var notice: Notice?

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
                if isWorking { workingOverlay }
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
            .sheet(item: $importSheet) { sheet in
                importSheetContent(sheet)
            }
            .background(
                Color.clear.alert(
                    "Import \u{201C}\(pendingImport?.name ?? "")\u{201D}",
                    isPresented: $showImportPrompt
                ) {
                    Button("Choose folder") { importSheet = .folder }
                    Button("Cancel", role: .cancel) { pendingImport = nil }
                } message: {
                    Text("The text file lists \(pendingImport?.names.count ?? 0) videos. Next, pick the folder they're in (the parent folder that holds your subfolders) so the app can find them.")
                }
            )
            .background(
                Color.clear.alert(
                    notice?.title ?? "",
                    isPresented: Binding(
                        get: { notice != nil },
                        set: { if !$0 { notice = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(notice?.message ?? "")
                }
            )
        }
    }

    // MARK: - Import from a text file

    @ViewBuilder
    private func importSheetContent(_ sheet: ImportSheet) -> some View {
        switch sheet {
        case .textFile:
            TextFilePicker(
                onPick: { url in readImportFile(url) },
                onCancel: { importSheet = nil }
            )
        case .folder:
            FolderPicker(
                onPick: { url in
                    importSheet = nil
                    runImport(from: url)
                },
                onCancel: {
                    importSheet = nil
                    pendingImport = nil
                }
            )
        }
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Matching videos…")
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(24)
            .cardStyle(cornerRadius: 20)
        }
    }

    /// Reads one filename per line (the format the queue export writes).
    private func readImportFile(_ url: URL) {
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? ""
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        let names = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
        importSheet = nil

        guard !names.isEmpty else {
            notice = Notice(title: "Nothing to import", message: "That text file has no lines in it.")
            return
        }
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(" queue") { name = String(name.dropLast(" queue".count)) }
        pendingImport = PendingImport(name: name.isEmpty ? "Imported" : name, names: names)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)   // let the picker finish closing
            showImportPrompt = true
        }
    }

    private func runImport(from url: URL) {
        guard let pending = pendingImport else { return }
        isWorking = true
        let wanted = Set(pending.names)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(root: url, wantedNames: wanted, extensions: nil)
            }.value
            isWorking = false
            pendingImport = nil

            guard let rootBookmark = result.rootBookmark else {
                notice = Notice(title: "Couldn't open folder", message: "The app wasn't able to get access to that folder.")
                return
            }
            let rootID = store.registerRoot(name: result.rootName, bookmark: rootBookmark)
            var byName: [String: [ScannedFile]] = [:]
            for file in result.files { byName[file.name, default: []].append(file) }

            guard let outcome = store.importSession(name: pending.name, orderedNames: pending.names,
                                                    rootID: rootID, files: byName) else {
                notice = Notice(
                    title: "No videos found",
                    message: "None of the \(pending.names.count) filenames were found in that folder, so no session was created."
                )
                return
            }
            var message = "Created \u{201C}\(pending.name)\u{201D} with \(outcome.matched) videos, in the order of the text file."
            if outcome.missing > 0 {
                message += " \(outcome.missing) weren't found in that folder and were left out."
            }
            notice = Notice(title: "Session imported", message: message)
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
            IconButton(systemName: "square.and.arrow.down", size: 40) {
                importSheet = .textFile
            }
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
