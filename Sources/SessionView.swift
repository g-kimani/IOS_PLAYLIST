import SwiftUI

enum SessionSheet: Identifiable {
    case addVideos(AddPlacement)
    case addFolder(AddPlacement)
    case relink
    case share(URL)

    var id: String {
        switch self {
        case .addVideos(let p): return "addVideos-\(p)"
        case .addFolder(let p): return "addFolder-\(p)"
        case .relink: return "relink"
        case .share(let url): return "share-\(url.absoluteString)"
        }
    }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct SessionView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var sheet: SessionSheet?
    @State private var confirmDelete = false
    @State private var isWorking = false
    @State private var workingText = ""
    @State private var notice: Notice?

    var body: some View {
        ZStack {
            AppBackground()
            if let session = store.session(sessionID) {
                content(session)
            } else {
                // Session was deleted: leave this page.
                Color.clear.onAppear { dismiss() }
            }
            if isWorking { workingOverlay }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { active in
            sheetContent(active)
        }
        .alert("Delete session?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteSession(sessionID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(store.session(sessionID)?.name ?? "This session")\u{201D} and its queue will be deleted.")
        }
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

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ active: SessionSheet) -> some View {
        switch active {
        case .addVideos(let placement):
            VideoPicker(
                onPick: { urls in
                    store.addItems(makeQueueItems(from: urls), to: sessionID, placement: placement)
                    sheet = nil
                },
                onCancel: { sheet = nil }
            )
        case .addFolder(let placement):
            FolderPicker(
                onPick: { url in
                    sheet = nil
                    addFolder(url, placement: placement)
                },
                onCancel: { sheet = nil }
            )
        case .relink:
            FolderPicker(
                onPick: { url in
                    sheet = nil
                    if let s = store.session(sessionID) { relink(url, in: s) }
                },
                onCancel: { sheet = nil }
            )
        case .share(let url):
            ShareSheet(items: [url])
        }
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text(workingText)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(24)
            .cardStyle(cornerRadius: 20)
        }
    }

    // MARK: - Actions

    private func addFolder(_ url: URL, placement: AddPlacement) {
        isWorking = true
        workingText = "Scanning folder…"
        let sid = sessionID
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(root: url, wantedNames: nil, extensions: LibraryScanner.playableExtensions)
            }.value
            isWorking = false

            guard let rootBookmark = result.rootBookmark else {
                notice = Notice(title: "Couldn't open folder", message: "The app wasn't able to get access to that folder.")
                return
            }
            guard !result.files.isEmpty else {
                notice = Notice(title: "No videos found", message: "That folder has no mp4, m4v or mov videos in it.")
                return
            }
            let rootID = store.registerRoot(name: result.rootName, bookmark: rootBookmark)
            let items = result.files.map {
                QueueItem(name: $0.name, bookmark: $0.bookmark, folder: $0.folder, rootID: rootID, relativePath: $0.relativePath)
            }
            store.addItems(items, to: sid, placement: placement)
            let folderCount = Set(items.compactMap { $0.folder }).count
            let where_ = placement == .end ? "to the end of the queue" : "right after the current video"
            notice = Notice(
                title: "Folder added",
                message: "Added \(items.count) videos \(where_) (\(folderCount) subfolders)."
            )
        }
    }

    private func relink(_ url: URL, in session: Session) {
        isWorking = true
        workingText = "Matching videos…"
        let sid = sessionID
        let wanted = Set(session.queue.map { $0.name })
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(root: url, wantedNames: wanted, extensions: nil)
            }.value
            isWorking = false

            guard let rootBookmark = result.rootBookmark else {
                notice = Notice(title: "Couldn't open folder", message: "The app wasn't able to get access to that folder. Nothing was changed.")
                return
            }
            let rootID = store.registerRoot(name: result.rootName, bookmark: rootBookmark)
            var byName: [String: [ScannedFile]] = [:]
            for file in result.files { byName[file.name, default: []].append(file) }
            let summary = store.relink(sessionID: sid, rootID: rootID, files: byName)
            notice = Notice(title: "Relink finished", message: summary.message)
        }
    }

    private func exportQueue(_ session: Session) {
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let base = session.name
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileName = (base.isEmpty ? "Session" : base) + " queue.txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let text = session.queue.map { $0.name }.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            sheet = .share(url)
        } catch {
            notice = Notice(title: "Export failed", message: error.localizedDescription)
        }
    }

    // MARK: - Layout

    private func content(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(session.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)

                Menu {
                    Button {
                        exportQueue(session)
                    } label: {
                        Label("Export queue as text file", systemImage: "square.and.arrow.up")
                    }
                    .disabled(session.queue.isEmpty)

                    Button {
                        sheet = .relink
                    } label: {
                        Label("Relink videos from folder", systemImage: "link")
                    }
                    .disabled(session.queue.isEmpty)
                } label: {
                    CircleIcon(systemName: "ellipsis", size: 40)
                }

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

                // Choose where the new videos go, then pick videos or a folder.
                Menu {
                    Section("Add to end") {
                        Button {
                            sheet = .addVideos(.end)
                        } label: {
                            Label("Videos", systemImage: "film")
                        }
                        Button {
                            sheet = .addFolder(.end)
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                    }
                    Section("Add at current position") {
                        Button {
                            sheet = .addVideos(.afterCurrent)
                        } label: {
                            Label("Videos", systemImage: "film")
                        }
                        Button {
                            sheet = .addFolder(.afterCurrent)
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                    }
                } label: {
                    CircleIcon(systemName: "plus", size: 50)
                }

                IconButton(systemName: "trash", size: 50, tint: Theme.danger) { confirmDelete = true }
            }

            folderChips(session)

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

    /// The subfolders used by this session's queue (with their favourite weight if it isn't 1).
    @ViewBuilder
    private func folderChips(_ session: Session) -> some View {
        let folders = session.folderSummaries
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FOLDERS IN THIS SESSION")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(folders) { folder in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").font(.caption2)
                                Text(folder.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(folder.count)")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                if session.weight(for: folder.name) > 1 {
                                    Text("\u{00D7}\(session.weight(for: folder.name))")
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(Theme.accent2)
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    /// Drag the handle on the right of a row to reorder the queue.
    private func queueList(_ session: Session) -> some View {
        ScrollViewReader { proxy in
            List {
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                .onMove { source, destination in
                    store.moveItems(from: source, to: destination, in: session.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .onAppear {
                if session.queue.indices.contains(session.position) {
                    proxy.scrollTo(session.queue[session.position].id, anchor: .center)
                }
            }
        }
    }
}
