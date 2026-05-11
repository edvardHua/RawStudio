import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No RAW Photos", systemImage: "photo.stack")
        } description: {
            Text("No RAW photos found. Import camera photos to your library and they will appear here automatically.")
        }
    }
}

#Preview {
    EmptyStateView()
}
