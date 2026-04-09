import SwiftUI

struct ActionBarView: View {
    var onKeepJPG: (() -> Void)?
    var onKeepRAW: (() -> Void)?
    var onExportHDR: (() -> Void)?
    var onExportUltraHDR: (() -> Void)?

    private var hasBasicActions: Bool {
        onKeepJPG != nil || onKeepRAW != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if let onKeepJPG {
                actionButton(title: "Save JPG", icon: "photo", action: onKeepJPG)
            }
            if let onKeepRAW {
                if onKeepJPG != nil { divider }
                actionButton(title: "Save RAW", icon: "camera.filters", action: onKeepRAW)
            }

            if hasBasicActions {
                // When mixed with keep/split, show HDR as a single menu
                if onExportHDR != nil || onExportUltraHDR != nil {
                    divider
                    hdrMenuButton
                }
            } else {
                // HDR-only mode: show as separate buttons
                if let onExportHDR {
                    actionButton(title: "Adaptive HDR", icon: "photo.badge.checkmark", action: onExportHDR)
                }
                if let onExportUltraHDR {
                    if onExportHDR != nil { divider }
                    actionButton(title: "Ultra HDR", icon: "photo.badge.arrow.down", action: onExportUltraHDR)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
    }

    private var divider: some View {
        Divider().frame(height: 30)
    }

    private var hdrMenuButton: some View {
        Menu {
            if let onExportHDR {
                Button(action: onExportHDR) {
                    Label("Adaptive HDR (HEIF) — Apple", systemImage: "photo.badge.checkmark")
                }
            }
            if let onExportUltraHDR {
                Button(action: onExportUltraHDR) {
                    Label("Ultra HDR (JPEG) — Universal", systemImage: "photo.badge.arrow.down")
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.title3)
                Text("HDR")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Full") {
    VStack {
        Spacer()
        ActionBarView(
            onKeepJPG: {},
            onKeepRAW: {},
            onExportHDR: {},
            onExportUltraHDR: {}
        )
    }
}

#Preview("HDR Only") {
    VStack {
        Spacer()
        ActionBarView(
            onExportHDR: {},
            onExportUltraHDR: {}
        )
    }
}
