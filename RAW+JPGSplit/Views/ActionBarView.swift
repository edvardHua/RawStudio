import SwiftUI

struct ActionBarView: View {
    let onKeepJPG: () -> Void
    let onKeepRAW: () -> Void
    let onSplit: () -> Void
    var onExportHDR: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            actionButton(title: "Keep JPG", icon: "photo", action: onKeepJPG)
            divider
            actionButton(title: "Keep RAW", icon: "camera.filters", action: onKeepRAW)
            divider
            actionButton(title: "Split", icon: "rectangle.split.2x1", action: onSplit)
            if let onExportHDR {
                divider
                actionButton(title: "HDR", icon: "sun.max.fill", action: onExportHDR)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
    }

    private var divider: some View {
        Divider().frame(height: 30)
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

#Preview {
    VStack {
        Spacer()
        ActionBarView(
            onKeepJPG: {},
            onKeepRAW: {},
            onSplit: {},
            onExportHDR: {}
        )
    }
}
