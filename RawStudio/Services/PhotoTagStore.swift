import Foundation

@Observable
final class PhotoTagStore {
    private let prefix = "photoTag_"

    /// 内存字典：assetID -> tag。init 时一次性从 UserDefaults 扫入，后续读全走内存。
    /// 作为 @Observable stored property，mutation 会自动触发 SwiftUI 刷新。
    private(set) var tags: [String: PhotoTag] = [:]

    init() {
        let defaults = UserDefaults.standard
        var loaded: [String: PhotoTag] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix),
                  let raw = value as? String,
                  let tag = PhotoTag(rawValue: raw) else { continue }
            let assetID = String(key.dropFirst(prefix.count))
            loaded[assetID] = tag
        }
        self.tags = loaded
    }

    func tag(for assetID: String) -> PhotoTag? {
        tags[assetID]
    }

    func count(for tag: PhotoTag) -> Int {
        var n = 0
        for value in tags.values where value == tag { n += 1 }
        return n
    }

    func setTag(_ tag: PhotoTag?, for assetID: String) {
        let key = prefix + assetID
        if let tag {
            UserDefaults.standard.set(tag.rawValue, forKey: key)
            tags[assetID] = tag
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            tags.removeValue(forKey: assetID)
        }
    }

    /// 批量打标 / 清标（一次 dict 替换内完成，避免连续刷新）
    func setTag(_ tag: PhotoTag?, for assetIDs: [String]) {
        var next = tags
        for id in assetIDs {
            let key = prefix + id
            if let tag {
                UserDefaults.standard.set(tag.rawValue, forKey: key)
                next[id] = tag
            } else {
                UserDefaults.standard.removeObject(forKey: key)
                next.removeValue(forKey: id)
            }
        }
        tags = next
    }
}
