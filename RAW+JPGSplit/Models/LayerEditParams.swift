import Foundation

/// The type of segmentation layer
enum LayerType: String, Codable, CaseIterable, Identifiable {
    case global
    case person
    case foreground
    case background

    var id: String { rawValue }

    var label: String {
        switch self {
        case .global: return String(localized: "Global")
        case .person: return String(localized: "Person")
        case .foreground: return String(localized: "Foreground")
        case .background: return String(localized: "Background")
        }
    }

    var icon: String {
        switch self {
        case .global: return "photo"
        case .person: return "person.fill"
        case .foreground: return "square.stack.3d.up.fill"
        case .background: return "mountain.2.fill"
        }
    }
}

/// Per-layer adjustments using CIFilter chain (5 common parameters)
struct LayerEditParams: Codable, Equatable {
    var exposure: Float = 0.0       // -3.0 ~ +3.0
    var brightness: Float = 0.0     // -0.5 ~ +0.5
    var contrast: Float = 1.0       // 0.5 ~ 2.0
    var saturation: Float = 1.0     // 0 ~ 2.0
    var temperature: Float = 6500.0 // 2000 ~ 10000

    var isModified: Bool {
        self != LayerEditParams()
    }

    mutating func reset() {
        self = LayerEditParams()
    }
}

/// Collection of all layer adjustments for a single image
struct LayerEdits: Codable, Equatable {
    var person: LayerEditParams = LayerEditParams()
    var foreground: LayerEditParams = LayerEditParams()
    var background: LayerEditParams = LayerEditParams()

    var hasAnyLayerEdits: Bool {
        person.isModified || foreground.isModified || background.isModified
    }

    func params(for layer: LayerType) -> LayerEditParams {
        switch layer {
        case .global: return LayerEditParams() // global uses separate params
        case .person: return person
        case .foreground: return foreground
        case .background: return background
        }
    }

    mutating func setParams(_ params: LayerEditParams, for layer: LayerType) {
        switch layer {
        case .global: break
        case .person: person = params
        case .foreground: foreground = params
        case .background: background = params
        }
    }
}
