import Foundation

struct ScannedFile: Sendable {
    let name: String
    let relativePath: String
    let folder: String?   // first-level subfolder under the library folder (nil if directly inside it)
    let bookmark: Data
}

struct ScanResult: Sendable {
    var rootName: String
    var rootBookmark: Data?
    var files: [ScannedFile]
}

enum LibraryScanner {
    /// Formats iPhone playback supports.
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Walks a library folder (including subfolders) and creates a bookmark for each file wanted.
    /// - wantedNames: only keep files with these exact names (used by relink)
    /// - extensions: only keep files with these extensions (used by add folder)
    static func scan(root: URL, wantedNames: Set<String>?, extensions: Set<String>?) -> ScanResult {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let rootBookmark = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let rootPath = root.standardizedFileURL.path
        var files: [ScannedFile] = []

        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

                let name = url.lastPathComponent
                if let extensions = extensions, !extensions.contains(url.pathExtension.lowercased()) { continue }
                if let wanted = wantedNames, !wanted.contains(name) { continue }

                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { continue }
                let relative = String(full.dropFirst(rootPath.count + 1))
                let parts = relative.split(separator: "/")
                let folder = parts.count > 1 ? String(parts[0]) : nil

                guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
                files.append(ScannedFile(name: name, relativePath: relative, folder: folder, bookmark: bookmark))
            }
        }

        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return ScanResult(rootName: root.lastPathComponent, rootBookmark: rootBookmark, files: files)
    }
}

// MARK: - Finding a queue item's file at play time

struct ResolvedFile {
    let url: URL
    let scopedURLs: [URL]        // call stopAccessingSecurityScopedResource on these when done
    let refreshedBookmark: Data?
}

enum FileResolver {
    static func resolve(_ item: QueueItem, store: SessionStore) -> ResolvedFile? {
        let fm = FileManager.default

        let fallback: (root: LibraryRoot, relativePath: String)? = {
            guard let rootID = item.rootID, let rel = item.relativePath, let root = store.root(rootID) else { return nil }
            return (root, rel)
        }()

        // 1. The video's own bookmark (the only route for videos added the old way).
        var stale = false
        if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            let scoped = url.startAccessingSecurityScopedResource()
            if fallback == nil || fm.isReadableFile(atPath: url.path) {
                let fresh = stale ? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
                return ResolvedFile(url: url, scopedURLs: scoped ? [url] : [], refreshedBookmark: fresh)
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        // 2. Backup route: the library folder's bookmark plus the file's path inside it.
        if let fallback = fallback {
            var rootStale = false
            if let rootURL = try? URL(resolvingBookmarkData: fallback.root.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &rootStale) {
                let scoped = rootURL.startAccessingSecurityScopedResource()
                let candidate = rootURL.appendingPathComponent(fallback.relativePath)
                if fm.isReadableFile(atPath: candidate.path) {
                    return ResolvedFile(url: candidate, scopedURLs: scoped ? [rootURL] : [], refreshedBookmark: nil)
                }
                if scoped { rootURL.stopAccessingSecurityScopedResource() }
            }
        }

        return nil
    }
}
