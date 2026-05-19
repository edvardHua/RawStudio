import SwiftUI

enum PhotoTag: String, CaseIterable, Identifiable, Codable {
    case red
    case orange
    case yellow
    case green
    case blue

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        }
    }

    var label: String {
        switch self {
        case .red:    return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green:  return String(localized: "Green")
        case .blue:   return String(localized: "Blue")
        }
    }
}
