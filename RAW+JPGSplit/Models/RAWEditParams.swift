import Foundation

/// All adjustable RAW editing parameters backed by CIRAWFilter properties.
struct RAWEditParams: Codable, Equatable {

    // MARK: - Exposure Group

    /// Exposure compensation in EV. CIRAWFilter.exposure
    var exposure: Float = 0.0           // -3.0 ~ +3.0

    /// Overall brightness boost. CIRAWFilter.boostAmount
    var boostAmount: Float = 1.0        // 0 ~ 2.0

    /// Shadow-specific boost. CIRAWFilter.boostShadowAmount
    var boostShadowAmount: Float = 0.0  // 0 ~ 2.0

    /// Contrast. CIRAWFilter.contrastAmount (check isContrastSupported)
    var contrastAmount: Float = 1.0     // 0 ~ 2.0

    /// Local tone mapping. CIRAWFilter.localToneMapAmount (check isLocalToneMapSupported)
    var localToneMapAmount: Float = 0.0 // 0 ~ 1.0

    /// Highlight recovery. CIRAWFilter.isHighlightRecoveryEnabled
    var highlightRecoveryEnabled: Bool = false

    // MARK: - Color Group

    /// Color temperature in Kelvin. CIRAWFilter.neutralTemperature
    var temperature: Float = 5000.0     // 2000 ~ 10000

    /// Tint (green-magenta). CIRAWFilter.neutralTint
    var tint: Float = 0.0              // -150 ~ +150

    /// Gamut mapping. CIRAWFilter.isGamutMappingEnabled
    var gamutMappingEnabled: Bool = true

    // MARK: - Detail Group

    /// Sharpness. CIRAWFilter.sharpnessAmount (check isSharpnessSupported)
    var sharpnessAmount: Float = 0.0    // 0 ~ 2.0

    /// Detail enhancement. CIRAWFilter.detailAmount (check isDetailSupported)
    var detailAmount: Float = 0.0       // 0 ~ 3.0

    /// Luminance noise reduction. CIRAWFilter.luminanceNoiseReductionAmount
    var luminanceNoiseReduction: Float = 0.0  // 0 ~ 1.0

    /// Color noise reduction. CIRAWFilter.colorNoiseReduction
    var colorNoiseReduction: Float = 0.0      // 0 ~ 1.0

    /// Moire reduction. CIRAWFilter.moireReductionAmount
    var moireReduction: Float = 0.0           // 0 ~ 1.0

    // MARK: - Lens Group

    /// Lens correction. CIRAWFilter.isLensCorrectionEnabled
    var lensCorrectionEnabled: Bool = false

    // MARK: - Helpers

    /// Whether any parameter differs from default
    var isModified: Bool {
        self != RAWEditParams()
    }

    /// Reset all parameters to defaults
    mutating func reset() {
        self = RAWEditParams()
    }
}

/// A named preset containing saved edit parameters.
struct RAWEditPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var params: RAWEditParams
    var createdAt: Date = Date()
}
