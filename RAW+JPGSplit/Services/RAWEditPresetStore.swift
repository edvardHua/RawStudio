import Foundation

/// Manages persistence of RAW edit presets and per-asset edit parameters.
@Observable
final class RAWEditPresetStore {

    /// All saved presets
    var presets: [RAWEditPreset] = []

    private let presetsKey = "rawEditPresets"
    private let assetParamsPrefix = "rawEditParams_"

    init() {
        loadPresets()
    }

    // MARK: - Presets

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

    // MARK: - Per-Asset Params

    /// Load saved edit params for a specific asset, or return defaults.
    func loadParams(for assetID: String) -> RAWEditParams {
        let key = assetParamsPrefix + assetID
        guard let data = UserDefaults.standard.data(forKey: key),
              let params = try? JSONDecoder().decode(RAWEditParams.self, from: data) else {
            return RAWEditParams()
        }
        return params
    }

    /// Save edit params for a specific asset.
    func saveParams(_ params: RAWEditParams, for assetID: String) {
        let key = assetParamsPrefix + assetID
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Check if an asset has custom edit params.
    func hasParams(for assetID: String) -> Bool {
        let key = assetParamsPrefix + assetID
        return UserDefaults.standard.data(forKey: key) != nil
    }

    /// Remove saved params for an asset.
    func removeParams(for assetID: String) {
        let key = assetParamsPrefix + assetID
        UserDefaults.standard.removeObject(forKey: key)
    }
}
