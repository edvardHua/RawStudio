import Foundation

struct ExportOptions: Equatable {
    enum Source: Equatable {
        case original    // 保留原图
        case fromRaw     // 从 RAW 渲染
    }

    enum Format: Equatable {
        case jpg
        case heic
    }

    enum AlbumTarget: Equatable {
        case none
        case createNew(name: String)
        case existing(id: String)    // PHAssetCollection.localIdentifier
    }

    var source: Source
    var format: Format
    var useHDR: Bool
    var album: AlbumTarget
}
