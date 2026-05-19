import Foundation

@Observable
final class PhotoTagStore {
    private let prefix = "photoTag_"

    /// SwiftUI 订阅刷新触发器（UserDefaults.set 不触发 @Observable 通知）
    var changeCounter: Int = 0

    func tag(for assetID: String) -> PhotoTag? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + assetID) else {
            return nil
        }
        return PhotoTag(rawValue: raw)
    }

    func setTag(_ tag: PhotoTag?, for assetID: String) {
        let key = prefix + assetID
        if let tag {
            UserDefaults.standard.set(tag.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        changeCounter += 1
    }

    /// 批量打标 / 清标（一次 changeCounter 自增内完成，避免连续刷新）
    func setTag(_ tag: PhotoTag?, for assetIDs: [String]) {
        for id in assetIDs {
            let key = prefix + id
            if let tag {
                UserDefaults.standard.set(tag.rawValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        changeCounter += 1
    }
}
