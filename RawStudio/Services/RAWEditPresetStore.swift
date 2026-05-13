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
    private let usedRawPresetPrefix = "usedRawPreset_"
    private let usedJpgPresetPrefix = "usedJpgPreset_"

    /// 任意 UserDefaults 写操作后递增，迫使依赖此属性的 SwiftUI 视图重渲染。
    /// （UserDefaults.set 本身不触发 @Observable 通知）
    var changeCounter: Int = 0

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
        changeCounter += 1
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
        changeCounter += 1
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
        changeCounter += 1
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
        changeCounter += 1
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
        changeCounter += 1
    }

    // MARK: - Preset Usage Tracking

    /// 标记用户在此 asset 上套用过 RAW 预设
    func markRawPresetUsed(for assetID: String) {
        UserDefaults.standard.set(true, forKey: usedRawPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 标记用户在此 asset 上套用过 JPG 预设
    func markJpgPresetUsed(for assetID: String) {
        UserDefaults.standard.set(true, forKey: usedJpgPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 清掉 RAW 预设标记（用户把 RAW 重置为默认时调）
    func clearRawPresetUsed(for assetID: String) {
        UserDefaults.standard.removeObject(forKey: usedRawPresetPrefix + assetID)
        changeCounter += 1
    }

    /// 清掉 JPG 预设标记
    func clearJpgPresetUsed(for assetID: String) {
        UserDefaults.standard.removeObject(forKey: usedJpgPresetPrefix + assetID)
        changeCounter += 1
    }

    // MARK: - Edit Status Queries

    /// 实际产出是否不同于原图（任一编辑数据非默认即是）
    func isEdited(for assetID: String) -> Bool {
        if loadParams(for: assetID).isModified { return true }
        if loadJPGParams(for: assetID).isModified { return true }
        if loadLayerEdits(for: assetID).hasAnyLayerEdits { return true }
        if loadJPGLayerEdits(for: assetID).hasAnyLayerEdits { return true }
        return false
    }

    /// 是否曾套用过任一预设（RAW 或 JPG）
    func hasUsedPreset(for assetID: String) -> Bool {
        UserDefaults.standard.bool(forKey: usedRawPresetPrefix + assetID) ||
        UserDefaults.standard.bool(forKey: usedJpgPresetPrefix + assetID)
    }
}
