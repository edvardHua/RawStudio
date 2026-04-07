import Foundation

/// Manages persistence of RAW/JPG edit presets and per-asset edit parameters.
@Observable
final class RAWEditPresetStore {

    /// All saved RAW presets
    var presets: [RAWEditPreset] = []

    /// All saved JPG presets
    var jpgPresets: [JPGEditPreset] = []

    private let presetsKey = "rawEditPresets"
    private let jpgPresetsKey = "jpgEditPresets"
    private let assetParamsPrefix = "rawEditParams_"
    private let jpgAssetParamsPrefix = "jpgEditParams_"
    private let layerEditsPrefix = "layerEdits_"
    private let jpgLayerEditsPrefix = "layerEdits_jpg_"

    init() {
        loadPresets()
        loadJPGPresets()
    }

    // MARK: - RAW Presets

    func savePreset(name: String, params: RAWEditParams) {
        let preset = RAWEditPreset(name: name, params: params)
        presets.append(preset)
        persistPresets()
    }

    func deletePreset(_ preset: RAWEditPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([RAWEditPreset].self, from: data) else {
            return
        }
        presets = decoded
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    // MARK: - JPG Presets

    func saveJPGPreset(name: String, params: JPGEditParams) {
        let preset = JPGEditPreset(name: name, params: params)
        jpgPresets.append(preset)
        persistJPGPresets()
    }

    func deleteJPGPreset(_ preset: JPGEditPreset) {
        jpgPresets.removeAll { $0.id == preset.id }
        persistJPGPresets()
    }

    private func loadJPGPresets() {
        guard let data = UserDefaults.standard.data(forKey: jpgPresetsKey),
              let decoded = try? JSONDecoder().decode([JPGEditPreset].self, from: data) else {
            return
        }
        jpgPresets = decoded
    }

    private func persistJPGPresets() {
        if let data = try? JSONEncoder().encode(jpgPresets) {
            UserDefaults.standard.set(data, forKey: jpgPresetsKey)
        }
    }

    // MARK: - Per-Asset RAW Params

    /// Load saved RAW edit params for a specific asset, or return defaults.
    func loadParams(for assetID: String) -> RAWEditParams {
        let key = assetParamsPrefix + assetID
        guard let data = UserDefaults.standard.data(forKey: key),
              let params = try? JSONDecoder().decode(RAWEditParams.self, from: data) else {
            return RAWEditParams()
        }
        return params
    }

    /// Save RAW edit params for a specific asset.
    func saveParams(_ params: RAWEditParams, for assetID: String) {
        let key = assetParamsPrefix + assetID
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Check if an asset has custom RAW edit params.
    func hasParams(for assetID: String) -> Bool {
        let key = assetParamsPrefix + assetID
        return UserDefaults.standard.data(forKey: key) != nil
    }

    /// Remove saved RAW params for an asset.
    func removeParams(for assetID: String) {
        let key = assetParamsPrefix + assetID
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Per-Asset JPG Params

    /// Load saved JPG edit params for a specific asset, or return defaults.
    func loadJPGParams(for assetID: String) -> JPGEditParams {
        let key = jpgAssetParamsPrefix + assetID
        guard let data = UserDefaults.standard.data(forKey: key),
              let params = try? JSONDecoder().decode(JPGEditParams.self, from: data) else {
            return JPGEditParams()
        }
        return params
    }

    /// Save JPG edit params for a specific asset.
    func saveJPGParams(_ params: JPGEditParams, for assetID: String) {
        let key = jpgAssetParamsPrefix + assetID
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Per-Asset Layer Edits (RAW)

    /// Load saved RAW layer edits for a specific asset, or return defaults.
    func loadLayerEdits(for assetID: String) -> LayerEdits {
        let key = layerEditsPrefix + assetID
        guard let data = UserDefaults.standard.data(forKey: key),
              let edits = try? JSONDecoder().decode(LayerEdits.self, from: data) else {
            return LayerEdits()
        }
        return edits
    }

    /// Save RAW layer edits for a specific asset.
    func saveLayerEdits(_ edits: LayerEdits, for assetID: String) {
        let key = layerEditsPrefix + assetID
        if let data = try? JSONEncoder().encode(edits) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Per-Asset Layer Edits (JPG)

    /// Load saved JPG layer edits for a specific asset, or return defaults.
    func loadJPGLayerEdits(for assetID: String) -> LayerEdits {
        let key = jpgLayerEditsPrefix + assetID
        guard let data = UserDefaults.standard.data(forKey: key),
              let edits = try? JSONDecoder().decode(LayerEdits.self, from: data) else {
            return LayerEdits()
        }
        return edits
    }

    /// Save JPG layer edits for a specific asset.
    func saveJPGLayerEdits(_ edits: LayerEdits, for assetID: String) {
        let key = jpgLayerEditsPrefix + assetID
        if let data = try? JSONEncoder().encode(edits) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
