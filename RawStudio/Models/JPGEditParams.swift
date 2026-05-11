import Foundation

/// Adjustable parameters for JPG image editing using CIFilter chain.
struct JPGEditParams: Codable, Equatable {

    /// Exposure (EV). CIExposureAdjust inputEV
    var exposure: Float = 0.0           // -3.0 ~ +3.0

    /// Brightness. CIColorControls inputBrightness
    var brightness: Float = 0.0         // -0.5 ~ +0.5

    /// Contrast. CIColorControls inputContrast
    var contrast: Float = 1.0           // 0.5 ~ 2.0

    /// Saturation. CIColorControls inputSaturation
    var saturation: Float = 1.0         // 0 ~ 2.0

    /// Warmth (simulates color temperature). CITemperatureAndTint
    var warmth: Float = 6500.0          // 2000 ~ 10000

    /// Tint. CITemperatureAndTint
    var tint: Float = 0.0              // -150 ~ +150

    /// Highlights. CIHighlightShadowAdjust inputHighlightAmount
    var highlights: Float = 1.0         // 0 ~ 2.0

    /// Shadows. CIHighlightShadowAdjust inputShadowAmount
    var shadows: Float = 0.0            // -1.0 ~ 1.0

    /// Sharpness. CISharpenLuminance inputSharpness
    var sharpness: Float = 0.0          // 0 ~ 2.0

    /// Vibrance. CIVibrance inputAmount
    var vibrance: Float = 0.0           // -1.0 ~ 1.0

    /// Whether any parameter differs from default
    var isModified: Bool {
        self != JPGEditParams()
    }

    /// Reset all parameters to defaults
    mutating func reset() {
        self = JPGEditParams()
    }
}

/// A named preset containing saved JPG edit parameters.
struct JPGEditPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var params: JPGEditParams
    var createdAt: Date = Date()
}
