import Foundation

enum FolderPhotoKind: String, Sendable {
    case rawJpgPair = "RAW + JPG/HEIC"
    case rawOnly = "RAW only"
    case imageOnly = "Image only"
}

struct FolderPhotoFile: Hashable, Sendable {
    let url: URL
    let fileName: String
    let fileExtension: String
    let isRAW: Bool
}

struct FolderPhotoItem: Identifiable, Hashable, Sendable {
    let id: String
    let rawFile: FolderPhotoFile?
    let imageFile: FolderPhotoFile?
    let kind: FolderPhotoKind

    var title: String { rawFile?.fileName ?? imageFile!.fileName }
    var location: String { (rawFile ?? imageFile)!.url.deletingLastPathComponent().path }
}

struct FolderPhotoScanner {
    nonisolated static let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "pef", "srw", "3fr", "ari", "bay", "cap", "data", "dcs", "dcr", "drf", "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc", "mef", "mos", "mrw", "obm", "pxn", "rwl", "rwz", "x3f"]
    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "bmp", "gif", "webp"]

    func scan(root: URL, recursive: Bool = true) -> AsyncThrowingStream<[FolderPhotoItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let files = try enumerate(root: root, recursive: recursive)
                    let items = pair(files)
                    for start in stride(from: 0, to: items.count, by: 50) {
                        try Task.checkCancellation()
                        continuation.yield(Array(items[start..<min(start + 50, items.count)]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private func enumerate(root: URL, recursive: Bool) throws -> [FolderPhotoFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [FolderPhotoFile] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { enumerator.skipDescendants(); continue }
            if values?.isPackage == true || values?.isDirectory == true {
                if !recursive { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let raw = Self.rawExtensions.contains(ext)
            guard raw || Self.imageExtensions.contains(ext) else { continue }
            files.append(FolderPhotoFile(url: url, fileName: url.lastPathComponent, fileExtension: ext.uppercased(), isRAW: raw))
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    nonisolated private func pair(_ files: [FolderPhotoFile]) -> [FolderPhotoItem] {
        let groups = Dictionary(grouping: files) { file in
            file.url.deletingLastPathComponent().standardizedFileURL.path + "\u{0}" + file.url.deletingPathExtension().lastPathComponent.lowercased()
        }
        var result: [FolderPhotoItem] = []
        for group in groups.values {
            let raws = group.filter(\.isRAW)
            let images = group.filter { !$0.isRAW }
            if raws.count == 1 && images.count == 1 {
                let raw = raws[0], image = images[0]
                result.append(FolderPhotoItem(id: raw.url.path, rawFile: raw, imageFile: image, kind: .rawJpgPair))
            } else {
                for raw in raws { result.append(FolderPhotoItem(id: raw.url.path, rawFile: raw, imageFile: nil, kind: .rawOnly)) }
                for image in images { result.append(FolderPhotoItem(id: image.url.path, rawFile: nil, imageFile: image, kind: .imageOnly)) }
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
