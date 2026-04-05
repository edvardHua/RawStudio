import SwiftUI

struct ActionBarView: View {
    let onKeepJPG: () -> Void
    let onKeepRAW: () -> Void
    let onSplit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            actionButton(title: "Keep JPG", icon: "photo", action: onKeepJPG)
            Divider()
                .frame(height: 30)
            actionButton(title: "Keep RAW", icon: "camera.filters", action: onKeepRAW)
            Divider()
                .frame(height: 30)
            actionButton(title: "Split", icon: "rectangle.split.2x1", action: onSplit)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
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
            onSplit: {}
        )
    }
}
