import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Paired Photos", systemImage: "photo.stack")
        } description: {
            Text("No RAW+JPG paired photos found. Import camera photos to your library and paired photos will appear here automatically.")
        }
    }
}

#Preview {
    EmptyStateView()
}
