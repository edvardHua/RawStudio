import Photos

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let collection: PHAssetCollection

    init(collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? ""
        self.collection = collection
    }

    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
