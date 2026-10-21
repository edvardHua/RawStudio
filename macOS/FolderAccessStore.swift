import AppKit
import Foundation

@MainActor
@Observable
final class FolderAccessStore {
    enum AccessError: LocalizedError {
        case noSavedFolder
        case cannotCreateBookmark
        case accessDenied(URL)

        var errorDescription: String? {
            switch self {
            case .noSavedFolder: return "Choose a photo folder to begin scanning."
            case .cannotCreateBookmark: return "The selected folder permission could not be saved. Please choose it again."
            case .accessDenied(let url): return "RawStudio can no longer access \(url.lastPathComponent). Choose the folder again."
            }
        }
    }

    private(set) var folderURL: URL?
    private(set) var lastError: String?
    private var activeURL: URL?
    private var accessIsActive = false
    private let defaultsKey = "macOS.selectedFolderBookmark"

    init() {
        restoreBookmark()
    }

    func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Photo Folder"
        panel.message = "RawStudio scans this folder and its subfolders for images."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try activate(url, saveBookmark: true)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            try activate(url, saveBookmark: stale)
        } catch {
            lastError = "Saved folder access expired. Choose the folder again."
            folderURL = nil
        }
    }

    func beginAccess() throws -> URL {
        guard let url = activeURL else { throw AccessError.noSavedFolder }
        guard url.startAccessingSecurityScopedResource() else {
            throw AccessError.accessDenied(url)
        }
        accessIsActive = true
        return url
    }

    func endAccess() {
        guard accessIsActive, let activeURL else { return }
        activeURL.stopAccessingSecurityScopedResource()
        accessIsActive = false
    }

    private func activate(_ url: URL, saveBookmark: Bool) throws {
        guard url.startAccessingSecurityScopedResource() else { throw AccessError.accessDenied(url) }
        defer { url.stopAccessingSecurityScopedResource() }
        if saveBookmark {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        activeURL = url
        folderURL = url
        lastError = nil
    }
}
