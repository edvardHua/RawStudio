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

    var source: Source
    var format: Format
    var useHDR: Bool
    var newAlbumName: String?    // nil = 不创建相册
}
